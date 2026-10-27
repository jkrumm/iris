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
  type Step,
  type StepOutcome,
} from "./memo.js";
import type { MemoStore } from "./store.js";

export interface StepResult {
  /** `route` only: park the memo in `needs_route` instead of advancing it. */
  outcome?: StepOutcome;
  usage?: unknown;
  costUsd?: number;
}

export type StepHandler = (ctx: { memo: Memo }) => Promise<StepResult>;

export interface Runner {
  /**
   * Runs the memo forward from its current state until it parks, finishes or fails. Single-flight
   * per memo: a call while one is running joins it, and the loop re-checks state before settling.
   */
  drive(id: string): Promise<void>;
  /** Startup recovery: resumes every memo that was mid-pipeline when the process stopped. */
  driveAll(): Promise<void>;
  /** Resets a failed memo to before `from` and drives it in the background. Returns the reset memo. */
  retry(params: { id: string; from: Step }): Memo;
}

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
  const rerun = new Set<string>();
  const warnedNoHandler = new Set<HandlerStep>();

  const publish = (id: string, step: Step | null) => {
    const memo = store.getMemo(id);
    if (memo) events.publish(memoEvent({ memo, step, clock }));
  };

  /** The memo plus the step and handler to run next, or null when the loop should stop. */
  function nextRunnable(id: string) {
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

  /** Returns false when the memo failed, or lost its state to a concurrent writer. */
  async function runStep(params: { memo: Memo; step: HandlerStep; handler: StepHandler }) {
    const { memo, step, handler } = params;
    store.markStepStarted({ id: memo.id, step });
    try {
      const result = await withSpan(`memo.${step}`, { memo_id: memo.id, step }, () =>
        handler({ memo }),
      );
      const to = advance({ state: memo.state, step, outcome: result.outcome });
      store.markStepDone({ id: memo.id, step, usage: result.usage, costUsd: result.costUsd });
      if (!store.transition({ id: memo.id, from: memo.state, to })) {
        log("runner.lost_transition", { memo_id: memo.id, step, from: memo.state, to });
        return false;
      }
    } catch (err) {
      store.markStepFailed({ id: memo.id, step, error: errorMessage(err) });
      publish(memo.id, step);
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
      } while (rerun.has(id));
    } finally {
      // Same tick as the rerun check: no drive() can slip in between and be dropped.
      inflight.delete(id);
    }
  }

  function drive(id: string) {
    const running = inflight.get(id);
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
      const memos = store.listNonTerminal();
      const results = await Promise.allSettled(memos.map((memo) => drive(memo.id)));
      results.forEach((result, i) => {
        if (result.status === "rejected") logDriveFailure(memos[i]?.id ?? "")(result.reason);
      });
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
