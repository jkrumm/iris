import type { ApnsEnv } from "./devices.js";

export type ApnsPushType = "alert" | "liveactivity";

/** The APNs request headers we set; the transport maps them onto `apns-*` headers. */
export interface ApnsHeaders {
  topic: string;
  pushType: ApnsPushType;
  priority: 5 | 10;
  /** Epoch seconds; omitted = no `apns-expiration`. */
  expiration?: number;
  collapseId?: string;
}

export interface ApnsMessage {
  headers: ApnsHeaders;
  /** The exact JSON body, `aps` dict included. */
  payload: Record<string, unknown>;
}

/**
 * `status` is the HTTP status, or 0 for a failure without a response (connection error, GOAWAY,
 * timeout). `reason` is APNs' `reason` string or the transport error message.
 */
export type ApnsResult = { ok: true } | { ok: false; status: number; reason: string };

export interface ApnsTransport {
  /** Resolves with a result for every outcome, including connection errors. */
  send(params: ApnsMessage & { environment: ApnsEnv; deviceToken: string }): Promise<ApnsResult>;
}
