import type { Clock } from "../ports/clock.js";
import { log } from "../telemetry/log.js";
import { traceIdFromMemoId, withRootSpan, withSpan } from "../telemetry/otel.js";
import { MemoError } from "./errors.js";
import { memoEvent, type MemoEvents } from "./events.js";
import {
  advance,
  nextStep,
  stepIndex,
  STEPS,
  type HandlerStep,
  type Memo,
  type MemoPatch,
  type MemoState,
  type Step,
  type StepOutcome,
} from "./memo.js";
import type { MemoStore } from "./store.js";

export interface StepResult {
  /** `route` and `act`: park the memo in `needs_route` instead of advancing it. */
  outcome?: StepOutcome;
  usage?: unknown;
  costUsd?: number;
  /** Memo data columns to write atomically with the step completion. */
  patch?: MemoPatch;
}

export type StepHandler = (ctx: { memo: Memo }) => Promise<StepResult>;

export interface Runner {
  /**
   * Runs the memo forward from its current state until it parks, finishes or fails. Single-flight
   * per memo: a call while one is running joins it, and the loop re-checks state before settling.
   */
  drive(id: string): Promise<void>;
  /** Startup recovery: resumes every memo that was mid-pipeline, at most `MAX_CONCURRENT_DRIVES` at a time. */
  driveAll(): Promise<void>;
  /**
   * Graceful shutdown, step one: no new memo starts and no running loop starts another step. The
   * step currently executing finishes and completes normally. Not reversible.
   */
  stop(): void;
  /** Ids of the memos currently being driven. */
  inflightIds(): string[];
  /** Resolves once no memo is in flight and no `driveAll` is running. Never throws. */
  idle(): Promise<void>;
  /** Resets a failed memo to before `from` and drives it in the background. Returns the reset memo. */
  retry(params: { id: string; from: Step }): Memo;
}

const MAX_CONCURRENT_DRIVES = 3;

const errorMessage = (err: unknown) => (err instanceof Error ? err.message : String(err));

const logDriveFailure = (id: string) => (err: unknown) =>
  log("runner.drive_failed", { memo_id: id, error: errorMessage(err) });

export function createRunner(deps: {
  store: MemoStore;
  handlers: Partial<Record<HandlerStep, StepHandler>>;
  events: MemoEvents;
  clock: Clock;
}): Runner {
  const { store, handlers, events, clock } = deps;
  const inflight = new Map<string, Promise<void>>();
  const driveAlls = new Set<Promise<void>>();
  const rerun = new Set<string>();
  let stopping = false;
  // `stopping` flips from `stop()` while a loop awaits; reading it through a call keeps that visible to the linter.
  const isStopping = () => stopping;
  const warnedNoHandler = new Set<HandlerStep>();

  const publish = (id: string, step: Step | null) => {
    const memo = store.getMemo(id);
    if (memo) events.publish(memoEvent({ memo, step, clock }));
  };

  /** The memo plus the step and handler to run next, or null when the loop should stop. */
  function nextRunnable(id: string) {
    if (stopping) return null;
    const memo = store.getMemo(id);
    if (!memo) return null;
    const step = nextStep(memo.state);
    if (!step) return null;
    const handler = handlers[step];
    if (!handler) {
      if (!warnedNoHandler.has(step)) {
        warnedNoHandler.add(step);
        log("runner.no_handler", { memo_id: id, step });
      }
      return null;
    }
    return { memo, step, handler };
  }

  /**
   * Returns false when the memo failed, or lost its state to a concurrent writer. Only the handler
   * (and the outcome check) can fail the step; a store error is bookkeeping and propagates.
   */
  async function runStep(params: { memo: Memo; step: HandlerStep; handler: StepHandler }) {
    const { memo, step, handler } = params;
    store.markStepStarted({ id: memo.id, step });
    let result: StepResult;
    let to: MemoState;
    try {
      result = await withSpan(`memo.${step}`, { memo_id: memo.id, step }, () => handler({ memo }));
      to = advance({ state: memo.state, step, outcome: result.outcome });
    } catch (err) {
      store.markStepFailed({ id: memo.id, step, error: errorMessage(err) });
      publish(memo.id, step);
      return false;
    }
    let completed: boolean;
    try {
      completed = store.completeStep({
        id: memo.id,
        step,
        from: memo.state,
        to,
        usage: result.usage,
        costUsd: result.costUsd,
        patch: result.patch,
      });
    } catch (err) {
      // Not a step failure: the handler ran, the store did not. Propagate; the step row stays running.
      log("runner.bookkeeping_failed", { memo_id: memo.id, step, error: errorMessage(err) });
      throw err;
    }
    if (!completed) {
      log("runner.lost_transition", { memo_id: memo.id, step, from: memo.state, to });
      return false;
    }
    publish(memo.id, step);
    return true;
  }

  async function pass(id: string) {
    const first = nextRunnable(id);
    if (!first) return;
    await withRootSpan(
      {
        traceId: traceIdFromMemoId(id),
        name: "memo",
        attrs: { memo_id: id, mode: first.memo.mode, device: first.memo.device },
      },
      async () => {
        for (let next = nextRunnable(id); next; next = nextRunnable(id)) {
          if (!(await runStep(next))) return;
        }
      },
    );
  }

  async function loop(id: string) {
    try {
      do {
        rerun.delete(id);
        await pass(id);
      } while (rerun.has(id) && !isStopping());
    } finally {
      // Same tick as the rerun check: no drive() can slip in between and be dropped.
      inflight.delete(id);
    }
  }

  function drive(id: string) {
    const running = inflight.get(id);
    if (stopping) return running ?? Promise.resolve();
    if (running) {
      rerun.add(id);
      return running;
    }
    const started = Promise.resolve().then(() => loop(id));
    inflight.set(id, started);
    return started;
  }

  return {
    drive,

    async driveAll() {
      const queue = store.listNonTerminal().map((memo) => memo.id);
      const worker = async () => {
        for (let id = queue.shift(); id !== undefined && !isStopping(); id = queue.shift()) {
          await drive(id).catch(logDriveFailure(id));
        }
      };
      const run = Promise.all(Array.from({ length: MAX_CONCURRENT_DRIVES }, worker)).then(
        () => undefined,
      );
      driveAlls.add(run);
      try {
        await run;
      } finally {
        driveAlls.delete(run);
      }
    },

    stop() {
      stopping = true;
    },

    inflightIds: () => Array.from(inflight.keys()),

    async idle() {
      while (inflight.size > 0 || driveAlls.size > 0) {
        await Promise.allSettled([...inflight.values(), ...driveAlls]);
      }
    },

    retry({ id, from }) {
      const memo = store.getMemo(id);
      if (!memo) throw new MemoError("not_found", `memo ${id} not found`);
      if (memo.state !== "failed" || !memo.failedStep) {
        throw new MemoError("bad_state", `memo ${id} is ${memo.state}, only failed memos retry`);
      }
      if (
        from === "ingest" ||
        !STEPS.includes(from) ||
        stepIndex(from) > stepIndex(memo.failedStep)
      ) {
        throw new MemoError(
          "bad_request",
          `cannot retry from ${from}: failed at ${memo.failedStep}`,
        );
      }
      if (!store.resetForRetry({ id, from })) {
        throw new MemoError("bad_state", `memo ${id} is no longer failed`);
      }
      publish(id, null);
      drive(id).catch(logDriveFailure(id));
      const reset = store.getMemo(id);
      if (!reset) throw new MemoError("not_found", `memo ${id} not found`);
      return reset;
    },
  };
}
