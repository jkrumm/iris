import { Elysia } from "elysia";
import { MemoError, type MemoErrorCode } from "../memo/errors.js";

const STATUS: Record<MemoErrorCode, number> = {
  not_found: 404,
  conflict: 409,
  bad_state: 409,
  missing_segments: 422,
  too_large: 413,
  bad_request: 400,
  unavailable: 503,
  destination_unavailable: 409,
};

/**
 * The single MemoError → HTTP mapping. Body shape is `{error: <code>, message}`, plus `missing`
 * for `missing_segments` and `maxBytes` for `too_large`. Schema and parse failures become
 * `bad_request` too. Anything else (401 from the guard, unknown routes, bugs) keeps Elysia's default.
 */
export const httpErrors = new Elysia({ name: "http-errors" }).onError(
  { as: "global" },
  ({ code, error, set }) => {
    if (error instanceof MemoError) {
      set.status = STATUS[error.code];
      return {
        error: error.code,
        message: error.message,
        ...(error.payload.missing && { missing: error.payload.missing }),
        ...(error.payload.maxBytes !== undefined && { maxBytes: error.payload.maxBytes }),
      };
    }
    if (code === "VALIDATION") {
      const detail = error.valueError;
      set.status = 400;
      return {
        error: "bad_request",
        message: detail ? `${detail.path || "request"}: ${detail.message}` : "invalid request",
      };
    }
    if (code === "PARSE") {
      set.status = 400;
      return { error: "bad_request", message: "unparseable request body" };
    }
  },
);
