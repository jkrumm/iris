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

const PEM = /^-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----$/;
const PEM_LINE = 64;

/**
 * The key as node-apn needs it: real newlines, 64-character body lines. An env file holds the PEM on one line with
 * literal `\n`, and a 1Password concealed field turns its newlines into spaces; both are rebuilt from the body.
 * Anything that is not one PEM block is only unescaped.
 */
export function normalizePem(value: string): string {
  const unescaped = value.replaceAll("\\n", "\n").trim();
  const match = PEM.exec(unescaped);
  if (!match) return unescaped;
  const [, label, body = ""] = match;
  const lines = body.replace(/\s+/g, "").match(new RegExp(`.{1,${PEM_LINE}}`, "g")) ?? [];
  return [`-----BEGIN ${label}-----`, ...lines, `-----END ${label}-----`].join("\n");
}

/**
 * The APNs notifier only when all four credentials are set; otherwise the log stand-in, which is
 * the intended state until the app enrols (so it is not a `degraded` entry).
 */
export function selectNotifier(deps: { apns: ApnsConfig; devices: DeviceStore; clock: Clock }): {
  notifier: Notifier;
  kind: "apns" | "log";
  /** Closes the APNs connections; absent for the log notifier. */
  close?: () => Promise<void>;
} {
  const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC } = deps.apns;
  if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_TOPIC) {
    return { notifier: createLogNotifier(), kind: "log" };
  }
  const transport = createNodeApnsTransport({
    keyP8: normalizePem(APNS_KEY_P8),
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
    close: () => transport.close(),
  };
}
