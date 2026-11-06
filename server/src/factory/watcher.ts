import {
  FactoryError,
  type FactoryAlerter,
  type FactoryPushStore,
  type FactoryReader,
} from "../ports/factory.js";
import { log } from "../telemetry/log.js";
import { isDecisionAsk } from "./service.js";

export interface FactoryWatcherOptions {
  reader: FactoryReader;
  alerter: FactoryAlerter;
  pushes: FactoryPushStore;
  /** A `fleet` hint waits this long for more before the asks are read (a burst is one read). */
  debounceMs?: number;
  /** The safety poll when no hint arrives. */
  pollMs?: number;
  /** Reconnect backoff of the stream: doubles from `min` to `max`. */
  backoffMs?: { min: number; max: number };
  logger?: typeof log;
}

export interface FactoryWatcher {
  /** Begins following; returns at once. */
  start(): void;
  /** Stops following; a pass that is running finishes. */
  stop(): void;
  /** Resolves when the loops and a running pass are done (after `stop`). */
  idle(): Promise<void>;
  /** One read of the asks and the pushes it owes; never throws. Exposed for tests. */
  pass(): Promise<void>;
}

const DEFAULT_BACKOFF = { min: 1_000, max: 60_000 };

const sleepUnless = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    if (signal.aborted) return resolve();
    const done = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    signal.addEventListener("abort", done);
  });

/**
 * Pushes once per new decision ask. A pass reads `/v1/asks` and claims every open decision ask (`source decision`, an Issue,
 * not stale); the push store decides whether it still needs its alert (`claim`), so a restart, a replayed stream or two hints
 * in a row never push twice. The first ever scan (empty table) records what is open as announced without pushing, so switching
 * the feature on never replays old asks. A pass runs on the first start, on a debounced `fleet` hint from the change stream and
 * on a safety poll; a failure is logged and never reaches memos or the process.
 */
export function createFactoryWatcher(options: FactoryWatcherOptions): FactoryWatcher {
  const { reader, alerter, pushes } = options;
  const debounceMs = options.debounceMs ?? 1_000;
  const pollMs = options.pollMs ?? 60_000;
  const backoff = options.backoffMs ?? DEFAULT_BACKOFF;
  const logger = options.logger ?? log;
  const abort = new AbortController();
  const { signal } = abort;

  let silent = false;
  let running: Promise<void> | null = null;
  let rerun = false;
  let debounce: ReturnType<typeof setTimeout> | undefined;
  const loops: Promise<void>[] = [];

  async function scan(): Promise<void> {
    const asks = await reader.asks();
    for (const ask of asks) {
      if (!isDecisionAsk(ask) || ask.stale) continue;
      if (!pushes.claim(ask.id, { silent })) continue;
      const outcome = await alerter.alert(ask).catch((err: unknown) => {
        logger("factory.push_failed", { ask_id: ask.id, error: String(err) });
        return "retry" as const;
      });
      if (outcome === "retry") continue;
      pushes.markPushed(ask.id);
    }
    if (silent) {
      pushes.completeBaseline();
      silent = false;
    }
  }

  async function pass(): Promise<void> {
    if (running) {
      rerun = true;
      return running;
    }
    running = scan()
      .catch((err: unknown) => logger("factory.watch_failed", { error: String(err) }))
      .finally(() => {
        running = null;
      });
    await running;
    if (rerun && !signal.aborted) {
      rerun = false;
      await pass();
    }
  }

  const trigger = () => {
    if (signal.aborted) return;
    clearTimeout(debounce);
    debounce = setTimeout(() => void pass(), debounceMs);
  };

  async function follow(): Promise<void> {
    let cursor: string | undefined;
    let delay = backoff.min;
    while (!signal.aborted) {
      try {
        for await (const change of reader.follow(cursor, signal)) {
          delay = backoff.min;
          cursor = change.cursor ?? cursor;
          if (change.event === "fleet") trigger();
        }
      } catch (err) {
        if (signal.aborted) return;
        if (err instanceof FactoryError && err.code === "cursor_gone") {
          // Malformed or ahead of the factory's tables: start from now and read the resources again.
          cursor = undefined;
          trigger();
          continue;
        }
        logger("factory.stream_failed", { error: String(err), retry_ms: delay });
      }
      await sleepUnless(delay, signal);
      delay = Math.min(delay * 2, backoff.max);
      // A reconnect may have missed a hint.
      trigger();
    }
  }

  async function poll(): Promise<void> {
    while (!signal.aborted) {
      await sleepUnless(pollMs, signal);
      if (!signal.aborted) await pass();
    }
  }

  return {
    pass,
    start() {
      silent = pushes.startBaseline();
      logger("factory.watch_start", { baseline: silent });
      loops.push(pass().then(poll), follow());
    },
    stop() {
      abort.abort();
      clearTimeout(debounce);
    },
    async idle() {
      await Promise.all(loops);
      await running;
    },
  };
}
