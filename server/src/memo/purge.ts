import type { AssetStore } from "../ports/assets.js";
import type { AudioStore } from "../ports/audio.js";
import type { Clock } from "../ports/clock.js";
import type { SpeechCache } from "../ports/speaker.js";
import { log } from "../telemetry/log.js";
import { PURGE_AFTER_MS } from "./memo.js";
import type { MemoStore } from "./store.js";

/** How often the sweeper looks for soft-deleted memos past their undo window. */
export const PURGE_SWEEP_MS = 60_000;

export interface Purger {
  /** One pass: every memo deleted at least `PURGE_AFTER_MS` ago loses its files, then its rows. Returns the purged ids. */
  sweep(): Promise<string[]>;
  /** Sweeps now and then every `PURGE_SWEEP_MS`; a second call is a no-op. */
  start(): void;
  /** Stops the timer; a sweep in flight keeps running, `idle()` waits for it. */
  stop(): void;
  idle(): Promise<void>;
}

/**
 * Removes a memo's audio (segments and the combined recording), speech and reply asset files first and its rows only once the
 * files are gone, so a failed removal leaves the memo to the next pass instead of orphaning files nothing points at.
 * A failure per memo is logged (`memo.purge_failed`) and never stops the rest of the sweep; a pass that cannot even list
 * the memos rejects `sweep()`, and the timer logs it as `memo.sweep_failed`.
 */
export function createPurger(deps: {
  store: MemoStore;
  audio: AudioStore;
  speechCache: SpeechCache;
  assets: AssetStore;
  clock: Clock;
  intervalMs?: number | undefined;
}): Purger {
  const { store, audio, speechCache, assets, clock, intervalMs = PURGE_SWEEP_MS } = deps;
  let timer: ReturnType<typeof setInterval> | undefined;
  let running: Promise<string[]> | undefined;

  async function run(): Promise<string[]> {
    const cutoff = new Date(clock.now().getTime() - PURGE_AFTER_MS).toISOString();
    const purged: string[] = [];
    for (const id of store.listPurgeable(cutoff)) {
      try {
        await Promise.all([audio.remove(id), speechCache.remove(id), assets.removeAll(id)]);
        if (store.purge(id)) {
          purged.push(id);
          log("memo.purged", { memo_id: id });
        }
      } catch (err) {
        log("memo.purge_failed", { memo_id: id, error: String(err) });
      }
    }
    return purged;
  }

  // Passes never overlap: a caller during a pass waits for it.
  const sweep = () => {
    running ??= run().finally(() => {
      running = undefined;
    });
    return running;
  };
  // The timer has no caller to reject to: a failed pass (the listing itself threw) is logged and the next tick tries again.
  const quietSweep = () =>
    void sweep().catch((err: unknown) => log("memo.sweep_failed", { error: String(err) }));

  return {
    sweep,
    start() {
      if (timer) return;
      quietSweep();
      timer = setInterval(quietSweep, intervalMs);
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
    },
    async idle() {
      await running?.catch(() => undefined);
    },
  };
}
