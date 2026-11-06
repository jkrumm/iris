import { isDeadToken, isEnvironmentMismatch, isTransient } from "../notify/apns-result.js";
import { buildFactoryAlert } from "../notify/payloads.js";
import type { ApnsTransport } from "../ports/apns.js";
import type { DeviceStore } from "../ports/devices.js";
import type { FactoryAlerter } from "../ports/factory.js";
import { log } from "../telemetry/log.js";

/** Stands in while APNs is not configured: the ask is logged, nothing is sent. */
export function createLogFactoryAlerter(logger: typeof log = log): FactoryAlerter {
  return {
    async alert(ask) {
      logger("factory.push_logged", { ask_id: ask.id, issue: ask.issue });
      return "sent";
    },
  };
}

/**
 * One alert push per new decision ask, to every device with an APNs token. A dead token is cleared like the memo
 * notifier does; `sent` when at least one device accepted, `retry` only when none did and a failure was transient.
 */
export function createApnsFactoryAlerter(deps: {
  transport: ApnsTransport;
  devices: DeviceStore;
  topic: string;
  logger?: typeof log;
}): FactoryAlerter {
  const { transport, devices, topic } = deps;
  const logger = deps.logger ?? log;

  return {
    async alert(ask) {
      const targets = devices.listDevices().filter((d) => d.apnsToken !== null);
      if (targets.length === 0) {
        logger("factory.push_no_token", { ask_id: ask.id, issue: ask.issue });
        return "no_token";
      }
      const message = buildFactoryAlert({ topic, ask });
      let delivered = 0;
      let transient = 0;
      for (const target of targets) {
        const token = target.apnsToken as string;
        const result = await transport
          .send({
            ...message,
            environment: target.apnsEnv ?? "sandbox",
            deviceToken: token,
          })
          .catch((err: unknown) => ({ ok: false as const, status: 0, reason: String(err) }));
        if (result.ok) {
          delivered++;
          continue;
        }
        const fields = {
          ask_id: ask.id,
          device: target.device,
          status: result.status,
          reason: result.reason,
        };
        if (isTransient(result)) {
          transient++;
          logger("factory.push_transient", fields);
          continue;
        }
        if (isEnvironmentMismatch(result, target.apnsEnv)) {
          logger("factory.push_rejected", { ...fields, hint: "apnsEnv unknown, token kept" });
          continue;
        }
        logger("factory.push_rejected", fields);
        if (isDeadToken(result)) devices.clearApnsToken({ device: target.device, expected: token });
      }
      if (delivered > 0) {
        logger("factory.push_sent", { ask_id: ask.id, issue: ask.issue, devices: delivered });
        return "sent";
      }
      return transient > 0 ? "retry" : "rejected";
    },
  };
}
