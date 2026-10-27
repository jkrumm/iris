import type { Notifier } from "../ports/notifier.js";
import { log } from "../telemetry/log.js";

/** The stand-in notifier while APNs is not configured: one log line, no transcript or spoken text. */
export function createLogNotifier(opts: { logger?: typeof log } = {}): Notifier {
  const logger = opts.logger ?? log;
  return {
    async notify({ memo, summary }) {
      logger("notify.log", {
        memo_id: memo.id,
        device: memo.device,
        headline: summary.headline,
        detail: summary.detail,
      });
    },
    async phase() {},
    async needsRoute({ memo, reason }) {
      logger("notify.needs_route_log", { memo_id: memo.id, device: memo.device, reason });
    },
  };
}
