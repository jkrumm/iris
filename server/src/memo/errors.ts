export const MEMO_ERROR_CODES = [
  "not_found",
  "conflict",
  "bad_state",
  "missing_segments",
  "too_large",
  "bad_request",
  "unavailable",
] as const;
export type MemoErrorCode = (typeof MEMO_ERROR_CODES)[number];

export interface MemoErrorPayload {
  missing?: number[];
  maxBytes?: number;
}

/** Domain failure the HTTP layer maps to a status by `code`. */
export class MemoError extends Error {
  constructor(
    readonly code: MemoErrorCode,
    message: string,
    readonly payload: MemoErrorPayload = {},
  ) {
    super(message);
    this.name = "MemoError";
  }
}

/** Narrows an optional dependency, answering `unavailable` (503) when its subsystem is not configured. */
export function configured<T>(dep: T | undefined, subsystem: string): T {
  if (dep === undefined) throw new MemoError("unavailable", `${subsystem} is not configured`);
  return dep;
}
