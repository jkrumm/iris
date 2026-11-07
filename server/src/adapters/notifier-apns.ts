import type { Memo } from "../memo/memo.js";
import {
  isDeadToken,
  isEnvironmentMismatch,
  isTransient,
  type ApnsFailure,
} from "../notify/apns-result.js";
import {
  buildAlert,
  buildLiveActivityDone,
  buildLiveActivityEnd,
  buildLiveActivityUpdate,
} from "../notify/payloads.js";
import type { ApnsMessage, ApnsResult, ApnsTransport } from "../ports/apns.js";
import type { Clock } from "../ports/clock.js";
import type { ApnsEnv, DeviceStore } from "../ports/devices.js";
import type { Notifier } from "../ports/notifier.js";
import { TransientError } from "../ports/transient.js";
import { log } from "../telemetry/log.js";

type Failure = ApnsFailure;
type Kind = "alert" | "live_activity_update" | "live_activity_done" | "live_activity_end";

/** What the device was told, for the log: the Live Activity `event` and whether an alert and its sound went out (never their text). */
function describePayload(payload: Record<string, unknown>) {
  const aps = (payload["aps"] ?? {}) as { event?: unknown; alert?: unknown; sound?: unknown };
  const alert = typeof aps.alert === "object" && aps.alert !== null ? aps.alert : null;
  const sound = aps.sound ?? (alert as { sound?: unknown } | null)?.sound ?? null;
  return {
    ...(typeof aps.event === "string" && { event: aps.event }),
    alert_present: alert !== null,
    sound: typeof sound === "string" ? sound : null,
  };
}

/**
 * Pushes through an `ApnsTransport`. A rejected token never fails the memo (it is logged, and
 * cleared when dead); a transient failure of the final push throws so the notify step fails and
 * `POST /retry` can re-drive it. Live Activity updates are best effort and never throw.
 */
export function createApnsNotifier(deps: {
  transport: ApnsTransport;
  devices: DeviceStore;
  /** The app bundle id; Live Activity pushes use `<topic>.push-type.liveactivity`. */
  topic: string;
  clock: Clock;
  logger?: typeof log;
}): Notifier {
  const { transport, devices, topic, clock } = deps;
  const logger = deps.logger ?? log;

  async function push(params: {
    kind: Kind;
    memo: Memo;
    token: string;
    message: ApnsMessage;
    clearToken: () => void;
  }): Promise<ApnsResult> {
    const { kind, memo, token, message, clearToken } = params;
    // An unregistered environment is pushed to the sandbox as a guess; see `isEnvironmentMismatch`.
    const apnsEnv: ApnsEnv | null = devices.getDevice(memo.device)?.apnsEnv ?? null;
    const result = await transport.send({
      ...message,
      environment: apnsEnv ?? "sandbox",
      deviceToken: token,
    });
    if (result.ok) {
      logger("notify.apns_sent", {
        memo_id: memo.id,
        device: memo.device,
        kind,
        push_type: message.headers.pushType,
        priority: message.headers.priority,
        environment: apnsEnv ?? "sandbox",
        ...describePayload(message.payload),
        status: 200,
      });
      return result;
    }
    const fields = {
      memo_id: memo.id,
      device: memo.device,
      kind,
      status: result.status,
      reason: result.reason,
    };
    if (isTransient(result)) {
      logger("notify.apns_transient", fields);
      return result;
    }
    if (isEnvironmentMismatch(result, apnsEnv)) {
      logger("notify.apns_rejected", {
        ...fields,
        hint: "apnsEnv is unknown, BadDeviceToken may be a sandbox/production mismatch; token kept",
      });
      return result;
    }
    logger("notify.apns_rejected", fields);
    if (isDeadToken(result)) clearToken();
    return result;
  }

  // The device may have re-registered a fresh token while the push was in flight; only clear the one we used.
  const clearDeviceToken = (memo: Memo, token: string) => () => {
    devices.clearApnsToken({ device: memo.device, expected: token });
  };

  const clearActivityToken = (memo: Memo, token: string) => () => {
    if (devices.getActivityToken(memo.id) === token) devices.clearActivityToken(memo.id);
  };

  return {
    async notify({ memo, summary }) {
      const activityToken = devices.getActivityToken(memo.id);
      const alertToken = devices.getDevice(memo.device)?.apnsToken ?? null;
      if (!activityToken && !alertToken) {
        logger("notify.no_token", { memo_id: memo.id, device: memo.device });
        return;
      }

      const now = clock.now();
      const results: ApnsResult[] = [];
      // A memo with a Live Activity is announced by a final `update` carrying the alert and its sound (Apple documents the alert sound for
      // `update`, not `end`; Issue 223), then the `end` without one: no separate banner. Without an activity token, or when the done push
      // is finally refused (the activity is gone), the alert push is the only way the device hears of the memo.
      if (activityToken) {
        const done = await push({
          kind: "live_activity_done",
          memo,
          token: activityToken,
          message: buildLiveActivityDone({ topic, memo, summary, now }),
          clearToken: clearActivityToken(memo, activityToken),
        });
        results.push(done);
        if (done.ok) {
          results.push(
            await push({
              kind: "live_activity_end",
              memo,
              token: activityToken,
              message: buildLiveActivityEnd({ topic, memo, summary, now }),
              clearToken: clearActivityToken(memo, activityToken),
            }),
          );
        }
      }
      const announced = results[0]?.ok === true;
      const doneTransient = results[0] !== undefined && !results[0].ok && isTransient(results[0]);
      if (alertToken && !announced && !doneTransient) {
        results.push(
          await push({
            kind: "alert",
            memo,
            token: alertToken,
            message: buildAlert({ topic, memo, summary }),
            clearToken: clearDeviceToken(memo, alertToken),
          }),
        );
      }

      const transient = results.find((r): r is Failure => !r.ok && isTransient(r));
      if (transient) {
        throw new TransientError(`apns: ${transient.status} ${transient.reason}`, "after_send");
      }
    },

    async phase({ memo }) {
      try {
        const token = devices.getActivityToken(memo.id);
        if (!token) return;
        await push({
          kind: "live_activity_update",
          memo,
          token,
          message: buildLiveActivityUpdate({ topic, memo, now: clock.now() }),
          clearToken: clearActivityToken(memo, token),
        });
      } catch (err) {
        logger("notify.phase_failed", { memo_id: memo.id, error: String(err) });
      }
    },
  };
}
