export type MemoErrorCode =
  | "not_found"
  | "conflict"
  | "bad_state"
  | "missing_segments"
  | "too_large"
  | "bad_request";

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
