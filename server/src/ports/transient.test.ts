import { describe, expect, it } from "bun:test";
import {
  fetchFailure,
  hangGuardFailure,
  httpFailure,
  TransientError,
  transientKind,
} from "./transient.js";

const withCode = (code: string, message = "fetch failed") =>
  Object.assign(new TypeError(message), { cause: Object.assign(new Error("x"), { code }) });

describe("fetchFailure", () => {
  it("marks a refused connection and a DNS failure before_send", () => {
    for (const code of ["ECONNREFUSED", "ENOTFOUND", "ConnectionRefused"]) {
      expect(transientKind(fetchFailure(withCode(code)))).toBe("before_send");
    }
  });

  it("marks a reset, a timeout, an abort and a bare fetch failure after_send", () => {
    expect(transientKind(fetchFailure(withCode("ECONNRESET")))).toBe("after_send");
    expect(transientKind(fetchFailure(new TypeError("fetch failed")))).toBe("after_send");
    expect(transientKind(fetchFailure(new DOMException("t", "TimeoutError")))).toBe("after_send");
    expect(transientKind(fetchFailure(new DOMException("a", "AbortError")))).toBe("after_send");
  });

  it("fails a timeout or abort for good when it is a hang guard", () => {
    for (const name of ["TimeoutError", "AbortError"]) {
      const failure = fetchFailure(new DOMException("t", name), { hangGuard: true });
      expect(failure).toBeInstanceOf(Error);
      expect(transientKind(failure)).toBeNull();
    }
  });

  it("still retries a refused or reset connection under a hang guard", () => {
    expect(transientKind(fetchFailure(withCode("ECONNREFUSED"), { hangGuard: true }))).toBe(
      "before_send",
    );
    expect(transientKind(fetchFailure(withCode("ECONNRESET"), { hangGuard: true }))).toBe(
      "after_send",
    );
  });

  it("returns anything else untouched", () => {
    const bug = new RangeError("boom");
    expect(fetchFailure(bug)).toBe(bug);
  });

  it("keeps an already marked error", () => {
    const marked = new TransientError("x", "before_send");
    expect(fetchFailure(marked)).toBe(marked);
  });
});

describe("httpFailure", () => {
  it("is transient for 5xx only", () => {
    expect(transientKind(httpFailure("down", 503))).toBe("after_send");
    expect(transientKind(httpFailure("bad", 400))).toBeNull();
    expect(transientKind(httpFailure("limit", 429))).toBeNull();
  });
});

describe("hangGuardFailure", () => {
  it("is a plain error with the cause kept", () => {
    const cause = new Error("idle");
    const failure = hangGuardFailure("stuck", { cause });
    expect(transientKind(failure)).toBeNull();
    expect(failure.cause).toBe(cause);
  });
});
