import { systemSleep, type Clock, type Sleep } from "../ports/clock.js";
import { transientKind, type TransientKind } from "../ports/transient.js";
import { log } from "../telemetry/log.js";
import { traceIdFromMemoId, withRootSpan, withSpan } from "../telemetry/otel.js";
import { MemoError } from "./errors.js";
import { memoEvent, type MemoEvents } from "./events.js";
import {
  advance,
  isOptionalStep,
  nextStep,
  stateAfter,
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

export interface StepContext {
  memo: Memo;
  /**
   * Wraps a wait that depends on another memo (a thread's turn ahead). While it is pending the memo gives up its
   * `driveAll` slot, so a parked waiter never keeps an unrelated memo from starting; the slot is taken back (queueing
   * behind whoever has it) before the wrapped promise settles. Outside `driveAll` it just awaits.
   */
  whileWaiting?: <T>(wait: Promise<T>) => Promise<T>;
}

export type StepHandler = (ctx: StepContext) => Promise<StepResult>;

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
  /**
   * Resets a failed memo to before `from` and drives it in the background. Returns the reset memo. A `notified` memo
   * whose optional `from` step failed retries too (its result is filled in later).
   */
  retry(params: { id: string; from: Step }): Memo;
}

const MAX_CONCURRENT_DRIVES = 3;

/** Backoff before each automatic retry of a transient failure: two retries, so three tries in all. */
export const RETRY_DELAYS_MS = [2_000, 8_000] as const;

/**
 * Whether a transient failure is worth another try. `act` delivers a side effect (a Hermes turn), so it only retries
 * when the request provably never reached the destination; every other step is safe to repeat.
 */
const retryable = (step: HandlerStep, kind: TransientKind | null) =>
  kind !== null && (step !== "act" || kind === "before_send");

const errorMessage = (err: unknown) => (err instanceof Error ? err.message : String(err));

const logDriveFailure = (id: string) => (err: unknown) =>
  log("runner.drive_failed", { memo_id: id, error: errorMessage(err) });

export function createRunner(deps: {
  store: MemoStore;
  handlers: Partial<Record<HandlerStep, StepHandler>>;
  events: MemoEvents;
  clock: Clock;
  /** Waits out a retry's backoff; tests inject an instant one. */
  sleep?: Sleep;
}): Runner {
  const { store, handlers, events, clock, sleep = systemSleep } = deps;
  const inflight = new Map<string, Promise<void>>();
  const driveAlls = new Set<Promise<void>>();
  const rerun = new Set<string>();
  let stopping = false;
  // Cuts a retry's backoff short when `stop()` is called.
  const stopped = Promise.withResolvers<void>();
  // `stopping` flips from `stop()` while a loop awaits; reading it through a call keeps that visible to the linter.
  const isStopping = () => stopping;
  const warnedNoHandler = new Set<HandlerStep>();

  // `driveAll` slots: at most `MAX_CONCURRENT_DRIVES` held at once. A memo parked on a thread queue lets its slot go.
  let freeSlots = MAX_CONCURRENT_DRIVES;
  const slotWaiters: (() => void)[] = [];
  const takeSlot = () =>
    freeSlots > 0
      ? (freeSlots--, Promise.resolve())
      : new Promise<void>((resolve) => slotWaiters.push(resolve));
  const giveSlot = () => {
    const next = slotWaiters.shift();
    if (next) next();
    else freeSlots++;
  };
  /** One per `driveAll` call waiting on or holding a slot; several can name the same memo, each is released and returned on its own. */
  interface Slot {
    held: boolean;
  }
  const slotsOf = new Map<string, Set<Slot>>();

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
   * Runs the handler, repeating it after a backoff while it keeps failing transiently; the last error propagates. Null
   * when `stop()` interrupted a retry: the step is neither done nor failed, and the next boot's `driveAll` re-runs it.
   */
  async function attempt(params: { memo: Memo; step: HandlerStep; handler: StepHandler }) {
    const { memo, step, handler } = params;
    const whileWaiting = async <T>(wait: Promise<T>): Promise<T> => {
      const held = [...(slotsOf.get(memo.id) ?? [])].filter((slot) => slot.held);
      if (held.length === 0) return wait;
      for (const slot of held) {
        slot.held = false;
        giveSlot();
      }
      try {
        return await wait;
      } finally {
        for (const slot of held) {
          await takeSlot();
          slot.held = true;
        }
      }
    };
    for (let tries = 1; ; tries++) {
      try {
        return await withSpan(`memo.${step}`, { memo_id: memo.id, step, attempt: tries }, () =>
          handler({ memo, whileWaiting }),
        );
      } catch (err) {
        const delayMs = RETRY_DELAYS_MS[tries - 1];
        if (delayMs === undefined || !retryable(step, transientKind(err))) throw err;
        if (stopping) return null;
        const error = errorMessage(err);
        if (store.markStepRetrying({ id: memo.id, step, error }) === null) throw err;
        log("step.retry", { memo_id: memo.id, step, attempt: tries + 1, delay_ms: delayMs, error });
        await withSpan(
          "memo.retry_wait",
          { memo_id: memo.id, step, attempt: tries + 1, delay_ms: delayMs, error },
          () => Promise.race([sleep(delayMs), stopped.promise]),
        );
        if (isStopping()) return null;
      }
    }
  }

  /**
   * Returns false when the memo failed, or lost its state to a concurrent writer. Only the handler
   * (and the outcome check) can fail the step; a store error is bookkeeping and propagates.
   */
  async function runStep(params: { memo: Memo; step: HandlerStep; handler: StepHandler }) {
    const { memo, step, handler } = params;
    store.markStepStarted({ id: memo.id, step });
    let result: StepResult | null;
    let to: MemoState;
    try {
      result = await attempt({ memo, step, handler });
      if (result === null) return false;
      to = advance({ state: memo.state, step, outcome: result.outcome });
    } catch (err) {
      const error = errorMessage(err);
      if (isOptionalStep(step)) {
        // The step stays failed on the timeline; the memo carries on without its result.
        const skipped = store.skipStep({
          id: memo.id,
          step,
          from: memo.state,
          to: stateAfter(step),
          error,
        });
        log("step.skipped", { memo_id: memo.id, step, error });
        if (skipped) publish(memo.id, step);
        return skipped;
      }
      store.markStepFailed({ id: memo.id, step, error });
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

  /** Drives one memo from a `driveAll` slot, waiting its turn for one. */
  async function driveInSlot(id: string) {
    const slot: Slot = { held: false };
    const slots = slotsOf.get(id) ?? new Set<Slot>();
    slots.add(slot);
    slotsOf.set(id, slots);
    try {
      await takeSlot();
      slot.held = true;
      if (!isStopping()) await drive(id).catch(logDriveFailure(id));
    } finally {
      if (slot.held) giveSlot();
      slots.delete(slot);
      if (slots.size === 0) slotsOf.delete(id);
    }
  }

  return {
    drive,

    async driveAll() {
      // One task per memo, started in order as slots free up.
      const ids = store.listNonTerminal().map((memo) => memo.id);
      const run = Promise.all(ids.map(driveInSlot)).then(() => undefined);
      driveAlls.add(run);
      try {
        await run;
      } finally {
        driveAlls.delete(run);
      }
    },

    stop() {
      stopping = true;
      stopped.resolve();
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
      if (from === "ingest" || !STEPS.includes(from)) {
        throw new MemoError("bad_request", `cannot retry from ${from}`);
      }
      // A finished memo retries only an optional step that failed on the way.
      const skippedOptional =
        memo.state === "notified" &&
        isOptionalStep(from) &&
        store.listStepRecords(id).some((r) => r.step === from && r.status === "failed");
      if (!skippedOptional) {
        if (memo.state !== "failed" || !memo.failedStep) {
          throw new MemoError("bad_state", `memo ${id} is ${memo.state}, only failed memos retry`);
        }
        if (stepIndex(from) > stepIndex(memo.failedStep)) {
          throw new MemoError(
            "bad_request",
            `cannot retry from ${from}: failed at ${memo.failedStep}`,
          );
        }
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
