import { createNodeApnsTransport } from "../adapters/apns-node.js";
import { createLogNotifier } from "../adapters/notifier-log.js";
import { createApnsNotifier } from "../adapters/notifier-apns.js";
import type { Clock } from "../ports/clock.js";
import type { DeviceStore } from "../ports/devices.js";
import type { Notifier } from "../ports/notifier.js";

export interface ApnsConfig {
  APNS_KEY_P8?: string | undefined;
  APNS_KEY_ID?: string | undefined;
  APNS_TEAM_ID?: string | undefined;
  APNS_TOPIC?: string | undefined;
}

/** An env file holds the PEM on one line with literal `\n`; node-apn needs real newlines. */
export const unescapeNewlines = (pem: string) => pem.replaceAll("\\n", "\n");

/**
 * The APNs notifier only when all four credentials are set; otherwise the log stand-in, which is
 * the intended state until the app enrols (so it is not a `degraded` entry).
 */
export function selectNotifier(deps: { apns: ApnsConfig; devices: DeviceStore; clock: Clock }): {
  notifier: Notifier;
  kind: "apns" | "log";
} {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC } = deps.apns;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) {
    return { notifier: createLogNotifier(), kind: "log" };
  }
  const transport = createNodeApnsTransport({
    keyP8: unescapeNewlines(APNS_KEY_P8),
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
  });
  return {
    notifier: createApnsNotifier({
      transport,
      devices: deps.devices,
      topic: APNS_TOPIC,
      clock: deps.clock,
    }),
    kind: "apns",
  };
}
