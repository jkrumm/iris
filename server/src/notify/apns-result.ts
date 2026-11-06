import type { ApnsResult } from "../ports/apns.js";
import type { ApnsEnv } from "../ports/devices.js";

export type ApnsFailure = Extract<ApnsResult, { ok: false }>;

/** Worth a retry: no response, throttled, APNs-side trouble, or a provider token node-apn could not refresh. */
export const isTransient = ({ status, reason }: ApnsFailure) =>
  status === 0 ||
  status === 408 ||
  status === 429 ||
  status >= 500 ||
  (status === 403 && reason === "ExpiredProviderToken");

/** The token itself is dead: APNs will never accept it again. */
export const isDeadToken = ({ status, reason }: ApnsFailure) =>
  status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";

/**
 * BadDeviceToken from a device that never registered its environment: the push went to the
 * sandbox by guess, and a valid production token is rejected exactly like this. Only an explicitly
 * registered environment makes BadDeviceToken proof of a dead token (410 / Unregistered always are).
 */
export const isEnvironmentMismatch = ({ status, reason }: ApnsFailure, apnsEnv: ApnsEnv | null) =>
  apnsEnv === null && status !== 410 && reason === "BadDeviceToken";
