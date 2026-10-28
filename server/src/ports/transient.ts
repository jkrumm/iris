/**
 * Where a transient failure happened relative to the request reaching its destination.
 * `before_send`: provably never delivered (connection refused, DNS). `after_send`: it may have been
 * (timeout, reset, 5xx), so a side-effecting step must not send it again.
 */
export type TransientKind = "before_send" | "after_send";

/** A downstream failure that another attempt may fix. Adapters throw it; the runner decides whether to retry. */
export class TransientError extends Error {
  constructor(
    message: string,
    readonly kind: TransientKind,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = "TransientError";
  }
}

export const transientKind = (err: unknown): TransientKind | null =>
  err instanceof TransientError ? err.kind : null;

/** An HTTP failure from a downstream: a 5xx is transient (the request was sent), anything else is final. */
export const httpFailure = (message: string, status: number): Error =>
  status >= 500 ? new TransientError(message, "after_send") : new Error(message);

const NOT_SENT_CODES = new Set([
  "ECONNREFUSED",
  "ConnectionRefused",
  "ENOTFOUND",
  "EAI_AGAIN",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "FailedToOpenSocket",
]);
const SENT_CODES = new Set([
  "ECONNRESET",
  "ConnectionClosed",
  "EPIPE",
  "ETIMEDOUT",
  "UND_ERR_SOCKET",
  "UND_ERR_CONNECT_TIMEOUT",
]);

const codeOf = (err: unknown): string | undefined => {
  if (typeof err !== "object" || err === null) return undefined;
  const { code, cause } = err as { code?: unknown; cause?: unknown };
  if (typeof code === "string") return code;
  return cause === undefined ? undefined : codeOf(cause);
};

/**
 * A call that outlived its hang guard (the 30-minute guard of a model call, an idle watchdog): the downstream is wedged,
 * so another try would only wait out the same window again. A plain error, never a `TransientError`: the step fails once.
 */
export const hangGuardFailure = (message: string, options?: { cause?: unknown }): Error =>
  new Error(message, options);

/**
 * Wraps what `fetch` threw: a timeout or abort, a reset or an unrecognised "fetch failed" is `after_send` (it may have
 * reached the server); a refused connection or a DNS failure is `before_send`. Anything else (a bug) is returned as is.
 * A call guarded by a hang guard (not a short "try again" timeout) throws `hangGuardFailure` itself instead.
 */
export function fetchFailure(err: unknown): unknown {
  if (err instanceof TransientError) return err;
  const message = err instanceof Error ? err.message : String(err);
  const name = err instanceof Error ? err.name : "";
  if (name === "TimeoutError" || name === "AbortError") {
    return new TransientError(`request timed out or aborted: ${message}`, "after_send", {
      cause: err,
    });
  }
  const code = codeOf(err);
  if (code !== undefined && NOT_SENT_CODES.has(code)) {
    return new TransientError(`connection failed (${code}): ${message}`, "before_send", {
      cause: err,
    });
  }
  if ((code !== undefined && SENT_CODES.has(code)) || /fetch failed/i.test(message)) {
    return new TransientError(`connection failed: ${message}`, "after_send", { cause: err });
  }
  return err;
}
