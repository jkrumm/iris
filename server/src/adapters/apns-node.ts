import { Notification, Provider, type ProviderOptions } from "@parse/node-apn";
import type { ApnsResult, ApnsTransport } from "../ports/apns.js";
import type { ApnsEnv } from "../ports/devices.js";

/**
 * Bun's `node:http2` client ignores the server's MAX_CONCURRENT_STREAMS and fires every request
 * at once (research §1), so we cap in-flight streams per process ourselves.
 */
export const MAX_INFLIGHT_STREAMS = 10;

export interface NodeApnsTransportOptions {
  /** PEM contents of the `.p8` key. */
  keyP8: string;
  keyId: string;
  teamId: string;
  maxInflight?: number;
  /** Per-environment node-apn options layered over the defaults; tests point `address` at a local server. */
  providerOptions?: Partial<Record<ApnsEnv, Partial<ProviderOptions>>>;
}

/** Counting semaphore: `run` waits for a free slot, so at most `limit` callbacks are in flight. */
function createLimiter(limit: number) {
  let active = 0;
  const waiting: (() => void)[] = [];
  return async function run<T>(fn: () => Promise<T>): Promise<T> {
    if (active >= limit) await new Promise<void>((resolve) => waiting.push(resolve));
    else active++;
    try {
      return await fn();
    } finally {
      const next = waiting.shift();
      if (next) next();
      else active--;
    }
  };
}

/** An APNs answer proves the provider token was valid (so the connection may fan out) unless it is an auth/throttle error. */
const provesAuth = (result: ApnsResult) =>
  result.ok ||
  (result.status >= 400 && result.status < 500 && ![403, 408, 429].includes(result.status));

/**
 * APNs over `@parse/node-apn`, one lazily created `Provider` (one HTTP/2 connection) per
 * environment. node-apn signs the ES256 JWT with `jsonwebtoken` and regenerates it once its
 * `iat` is 3300 s (55 min) old, checked on each request, which sits inside Apple's 20-60 min
 * window; it also retries 408/429/5xx and `ExpiredProviderToken` up to 3 times.
 *
 * Apple allows a single stream on a fresh connection until a request with a valid token lands,
 * so the first send per environment goes out alone; a connection-level failure makes the next
 * send a probe again.
 */
export function createNodeApnsTransport(
  options: NodeApnsTransportOptions,
): ApnsTransport & { close(): Promise<void> } {
  const limit = createLimiter(options.maxInflight ?? MAX_INFLIGHT_STREAMS);
  const providers = new Map<ApnsEnv, Provider>();
  const probes = new Map<ApnsEnv, { warm: boolean; inflight: Promise<unknown> | null }>();

  const providerFor = (environment: ApnsEnv) => {
    let provider = providers.get(environment);
    if (!provider) {
      provider = new Provider({
        token: { key: options.keyP8, keyId: options.keyId, teamId: options.teamId },
        production: environment === "production",
        ...options.providerOptions?.[environment],
      });
      providers.set(environment, provider);
    }
    return provider;
  };

  const sendOnce: ApnsTransport["send"] = async (params) => {
    try {
      const { headers, payload, deviceToken, environment } = params;
      const notification = new Notification({
        rawPayload: payload,
        topic: headers.topic,
        pushType: headers.pushType,
        priority: headers.priority,
        ...(headers.expiration !== undefined && { expiry: headers.expiration }),
        ...(headers.collapseId !== undefined && { collapseId: headers.collapseId }),
      });
      const { sent, failed } = await providerFor(environment).send(notification, deviceToken);
      const failure = failed[0];
      if (!failure) {
        return sent.length > 0
          ? { ok: true }
          : { ok: false, status: 0, reason: "no response from node-apn" };
      }
      const status = typeof failure.status === "number" ? failure.status : 0;
      return {
        ok: false,
        status,
        reason: failure.response?.reason ?? failure.error?.message ?? "unknown error",
      };
    } catch (err) {
      return { ok: false, status: 0, reason: err instanceof Error ? err.message : String(err) };
    }
  };

  return {
    async send(params) {
      const state = probes.get(params.environment) ?? { warm: false, inflight: null };
      probes.set(params.environment, state);
      while (!state.warm && state.inflight) await state.inflight;
      if (state.warm) {
        const result = await limit(() => sendOnce(params));
        if (!result.ok && result.status === 0) state.warm = false;
        return result;
      }

      const probe = limit(() => sendOnce(params));
      state.inflight = probe;
      const result = await probe;
      state.inflight = null;
      state.warm = provesAuth(result);
      return result;
    },

    async close() {
      await Promise.all(Array.from(providers.values(), (provider) => provider.shutdown()));
      providers.clear();
      probes.clear();
    },
  };
}
