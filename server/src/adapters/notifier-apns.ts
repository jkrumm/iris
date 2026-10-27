import type { Memo } from "../memo/memo.js";
import { buildAlert, buildLiveActivityEnd, buildLiveActivityUpdate } from "../notify/payloads.js";
import type { ApnsMessage, ApnsResult, ApnsTransport } from "../ports/apns.js";
import type { Clock } from "../ports/clock.js";
import type { ApnsEnv, DeviceStore } from "../ports/devices.js";
import type { Notifier } from "../ports/notifier.js";
import { log } from "../telemetry/log.js";

type Failure = Extract<ApnsResult, { ok: false }>;
type Kind = "alert" | "live_activity_update" | "live_activity_end";

/** Worth a retry: no response, throttled, APNs-side trouble, or a provider token node-apn could not refresh. */
const isTransient = ({ status, reason }: Failure) =>
  status === 0 ||
  status === 408 ||
  status === 429 ||
  status >= 500 ||
  (status === 403 && reason === "ExpiredProviderToken");

/** The token itself is dead: APNs will never accept it again. */
const isDeadToken = ({ status, reason }: Failure) =>
  status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";

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

  const environmentOf = (memo: Memo): ApnsEnv =>
    devices.getDevice(memo.device)?.apnsEnv ?? "sandbox";

  async function push(params: {
    kind: Kind;
    memo: Memo;
    token: string;
    message: ApnsMessage;
    clearToken: () => void;
  }): Promise<ApnsResult> {
    const { kind, memo, token, message, clearToken } = params;
    const result = await transport.send({
      ...message,
      environment: environmentOf(memo),
      deviceToken: token,
    });
    if (result.ok) return result;
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
    logger("notify.apns_rejected", fields);
    if (isDeadToken(result)) clearToken();
    return result;
  }

  // The device may have re-registered a fresh token while the push was in flight; only clear the one we used.
  const clearDeviceToken = (memo: Memo, token: string) => () => {
    const device = devices.getDevice(memo.device);
    if (device?.apnsToken !== token) return;
    devices.registerDevice({
      device: device.device,
      name: device.name,
      platform: device.platform,
      apnsToken: null,
    });
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
      const pushes: Promise<ApnsResult>[] = [];
      if (activityToken) {
        pushes.push(
          push({
            kind: "live_activity_end",
            memo,
            token: activityToken,
            message: buildLiveActivityEnd({ topic, memo, summary, now }),
            clearToken: clearActivityToken(memo, activityToken),
          }),
        );
      }
      if (alertToken) {
        pushes.push(
          push({
            kind: "alert",
            memo,
            token: alertToken,
            message: buildAlert({ topic, memo, summary }),
            clearToken: clearDeviceToken(memo, alertToken),
          }),
        );
      }

      const results = await Promise.all(pushes);
      const transient = results.find((r): r is Failure => !r.ok && isTransient(r));
      if (transient) throw new Error(`apns: ${transient.status} ${transient.reason}`);
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
