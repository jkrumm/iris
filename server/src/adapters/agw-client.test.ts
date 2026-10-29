import { describe, expect, it } from "bun:test";
import { z } from "zod";
import { TransientError, transientKind } from "../ports/transient.js";
import { createAgwClient } from "./agw-client.js";

const SECRET = "agw-secret-0123456789abcdef0123456789";
const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000004";
const Answer = z.object({ ok: z.boolean() });

function setup(respond: (init: RequestInit) => Response | Promise<Response>, timeoutMs?: number) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond(init ?? {});
  }) as typeof fetch;
  const client = createAgwClient({
    baseUrl: "http://127.0.0.1:7791//",
    secret: SECRET,
    fetch: fakeFetch,
    ...(timeoutMs !== undefined && { timeoutMs }),
  });
  const call = () => client.call({ memoId: "m", path: "/triage", body: { a: 1 }, schema: Answer });
  return { calls, call };
}

const json = (body: unknown, status = 200) =>
  Response.json(body, { status, headers: { "agw-run-id": RUN_ID } });

describe("agw client", () => {
  it("posts JSON with the bearer, purpose iris, a hang guard and no redirects", async () => {
    const { calls, call } = setup(() => json({ ok: true }));
    expect(await call()).toEqual({ data: { ok: true }, runId: RUN_ID });

    expect(calls[0]?.url).toBe("http://127.0.0.1:7791/triage");
    expect(calls[0]?.init.method).toBe("POST");
    expect(calls[0]?.init.headers).toEqual({
      "content-type": "application/json",
      authorization: `Bearer ${SECRET}`,
      "x-agw-purpose": "iris",
    });
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ a: 1 });
    expect(calls[0]?.init.redirect).toBe("error");
    expect(calls[0]?.init.signal).toBeInstanceOf(AbortSignal);
  });

  it("returns a null run id when the header is absent", async () => {
    const { call } = setup(() => Response.json({ ok: true }));
    expect((await call()).runId).toBeNull();
  });

  it.each([
    [400, "BAD_REQUEST"],
    [401, "UNAUTHORIZED"],
    [502, "INVALID_OUTPUT"],
  ])("%d %s is final and names the code and the run", async (status, code) => {
    const { call } = setup(() => json({ code, message: "nope" }, status));
    const err = await call().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(Error);
    expect(err).not.toBeInstanceOf(TransientError);
    expect((err as Error).message).toContain(`${status} ${code} (run ${RUN_ID})`);
  });

  it("a 502 that is not INVALID_OUTPUT is transient", async () => {
    const { call } = setup(() => new Response("Bad Gateway", { status: 502 }));
    expect(transientKind(await call().catch((e: unknown) => e))).toBe("after_send");
  });

  it("keeps the raw error body out of the error", async () => {
    const { call } = setup(() =>
      json({ code: "BAD_REQUEST", message: "transcript: Kauf Milch, geheim" }, 400),
    );
    const err = await call().catch((e: unknown) => e);
    expect((err as Error).message).not.toContain("geheim");
  });

  it("a 200 body that is not JSON is final", async () => {
    const { call } = setup(() => new Response("<html>", { headers: { "agw-run-id": RUN_ID } }));
    const err = await call().catch((e: unknown) => e);
    expect(err).not.toBeInstanceOf(TransientError);
    expect((err as Error).message).toContain(`response is not JSON (run ${RUN_ID})`);
  });

  it.each([500, 503])("%d is transient after the send", async (status) => {
    const { call } = setup(() => json({ code: "X", message: "down" }, status));
    const err = await call().catch((e: unknown) => e);
    expect(transientKind(err)).toBe("after_send");
    expect((err as Error).message).toContain(`(run ${RUN_ID})`);
  });

  it("a refused connection is transient before the send", async () => {
    const { call } = setup(() => {
      throw Object.assign(new Error("Unable to connect"), { code: "ConnectionRefused" });
    });
    expect(transientKind(await call().catch((e: unknown) => e))).toBe("before_send");
  });

  it("aborts the request at the hang guard with a final failure", async () => {
    const { call } = setup(
      (init) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener("abort", () => reject(init.signal?.reason));
        }),
      30,
    );
    const err = await call().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(Error);
    expect(err).not.toBeInstanceOf(TransientError);
    expect((err as Error).message).toContain("agw triage timed out after 30 ms");
  });

  it("an answer off the schema fails with the issues and the run", async () => {
    const { call } = setup(() => json({ ok: "yes" }));
    const err = await call().catch((e: unknown) => e);
    expect(err).not.toBeInstanceOf(TransientError);
    expect((err as Error).message).toContain(`does not match its schema (run ${RUN_ID}): ok`);
  });
});
