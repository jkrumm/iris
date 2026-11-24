import type { Clock } from "../ports/clock.js";
import { TAKE_ACTIVE_MS } from "./memo.js";
import type { MemoStore } from "./store.js";

/**
 * What /health reports as `inflight`: memos with a step running plus takes in progress (a `receiving` memo whose last
 * segment, or creation, is under `TAKE_ACTIVE_MS` old). The restart gates (mini-deploy.sh, `make launchd-restart`)
 * wait while it is above 0, so a restart never cuts a take; an abandoned take stops counting after the window.
 */
export function createBusyCount(params: {
  stepsRunning: () => number;
  store: Pick<MemoStore, "countActiveTakes">;
  clock: Clock;
}): () => number {
  const { stepsRunning, store, clock } = params;
  return () =>
    stepsRunning() +
    store.countActiveTakes(new Date(clock.now().getTime() - TAKE_ACTIVE_MS).toISOString());
}
