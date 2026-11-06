import { describe, expect, it } from "bun:test";
import { FactoryError } from "../ports/factory.js";
import { createFactoryHttp } from "./factory-http.js";

const TOKEN = "factory-token-0123456789";

function setup(respond: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond(String(input), init ?? {});
  }) as typeof fetch;
  const reader = createFactoryHttp({
    baseUrl: "http://127.0.0.1:7793//",
    token: TOKEN,
    fetch: fakeFetch,
    timeoutMs: 50,
    streamIdleMs: 50,
  });
  return { calls, reader };
}

const ask = {
  id: "decision:113:1:ask:u1",
  kind: "question",
  repo: "/Users/someone/repo",
  session: null,
  short: "Which cache layer?",
  summary: "Keep Redis or not.",
  text: "raw text",
  source: "decision",
  at: "2026-11-06T09:30:00.000Z",
  issue: 113,
  stale: false,
  futureField: 1,
};

describe("factory http reader", () => {
  it("reads the overview with the bearer, no redirects and a hang guard; drops repo paths and tolerates unknowns", async () => {
    const { calls, reader } = setup(() =>
      Response.json({
        builtAt: "2026-11-06T10:00:00.000Z",
        asks: [
          ask,
          { ...ask, id: "x", kind: "brand-new", source: "elsewhere", short: null },
          { nope: 1 },
        ],
        health: [
          {
            id: "h1",
            kind: "park",
            short: "Parked",
            summary: "One Issue is parked.",
            since: "2026-11-06T08:00:00.000Z",
          },
        ],
      }),
    );
    const overview = await reader.overview();

    expect(calls[0]?.url).toBe("http://127.0.0.1:7793/v1/overview");
    expect(calls[0]?.init.headers).toMatchObject({ authorization: `Bearer ${TOKEN}` });
    expect(calls[0]?.init.redirect).toBe("error");
    expect(calls[0]?.init.signal).toBeInstanceOf(AbortSignal);
    expect(overview.asks).toHaveLength(2);
    expect(overview.asks[0]).toEqual({
      id: ask.id,
      kind: "question",
      source: "decision",
      issue: 113,
      short: "Which cache layer?",
      summary: "Keep Redis or not.",
      at: ask.at,
      stale: false,
    });
    // Unknown enum values are "other"; a null short falls back to the summary.
    expect(overview.asks[1]).toMatchObject({
      kind: "other",
      source: "other",
      short: "Keep Redis or not.",
      issue: 113,
    });
    expect(overview.health).toEqual([
      {
        id: "h1",
        kind: "park",
        short: "Parked",
        summary: "One Issue is parked.",
        since: "2026-11-06T08:00:00.000Z",
      },
    ]);
  });

  it("reads the open question's options: the newest entry without an answer", async () => {
    const { calls, reader } = setup(() =>
      Response.json({
        asks: [
          { question: "old", options: ["a"], answer: "a" },
          { question: "new", options: ["Keep Redis", "Drop it"], default: null, answer: null },
        ],
      }),
    );
    expect(await reader.issueQuestion(113)).toEqual(["Keep Redis", "Drop it"]);
    expect(calls[0]?.url).toBe("http://127.0.0.1:7793/v1/issues/113");
  });

  it("answers outside /v1 with the call id and the text, no decision", async () => {
    const { calls, reader } = setup(() =>
      Response.json({ issue: 113, key: "k", duplicate: false, state: "working" }, { status: 201 }),
    );
    expect(await reader.answer({ issue: 113, callId: "call-1", text: "Keep Redis" })).toEqual({
      issue: 113,
      state: "working",
      duplicate: false,
    });
    expect(calls[0]?.url).toBe("http://127.0.0.1:7793/issues/113/answer");
    expect(calls[0]?.init.method).toBe("POST");
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ id: "call-1", answer: "Keep Redis" });
  });

  it.each([
    [404, "not_found"],
    [409, "conflict"],
    [410, "cursor_gone"],
    [400, "bad_request"],
    [401, "unavailable"],
    [503, "unavailable"],
  ])("maps status %i to %s", async (status, code) => {
    const { reader } = setup(() => Response.json({ error: "secret detail" }, { status }));
    const err = await reader.asks().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(FactoryError);
    expect(String((err as FactoryError).code)).toBe(code);
    expect((err as FactoryError).message).not.toContain("secret");
  });

  it("is unavailable when the connection fails or the body is not what was promised", async () => {
    const down = setup(() => {
      throw new TypeError("fetch failed");
    });
    expect(await down.reader.asks().catch((e: FactoryError) => e.code)).toBe("unavailable");
    const odd = setup(() => Response.json({ nothing: true }));
    expect(await odd.reader.overview().catch((e: FactoryError) => e.code)).toBe("unavailable");
    const html = setup(() => new Response("<html>"));
    expect(await html.reader.asks().catch((e: FactoryError) => e.code)).toBe("unavailable");
  });

  it("follows the stream with since, yielding the event and the frame's cursor", async () => {
    const body =
      'id: i1.s1\nevent: hello\ndata: {"cursor":"i1.s1"}\n\n: keepalive\n\nid: i2.s1\nevent: fleet\ndata: {}\n\nid: i3.s1\nevent: weird\ndata: {}\n\n';
    const { calls, reader } = setup(() => new Response(body));
    const seen = [];
    for await (const change of reader.follow("i0.s0", new AbortController().signal))
      seen.push(change);
    expect(seen).toEqual([
      { event: "hello", cursor: "i1.s1" },
      { event: "fleet", cursor: "i2.s1" },
      { event: "other", cursor: "i3.s1" },
    ]);
    expect(calls[0]?.url).toBe("http://127.0.0.1:7793/v1/stream?since=i0.s0");
    expect(calls[0]?.init.headers).toMatchObject({ accept: "text/event-stream" });
  });

  it("starts a stream without since, and a 410 is cursor_gone", async () => {
    const fresh = setup(() => new Response(""));
    for await (const _ of fresh.reader.follow(undefined, new AbortController().signal)) void _;
    expect(fresh.calls[0]?.url).toBe("http://127.0.0.1:7793/v1/stream");

    const gone = setup(() => new Response("", { status: 410 }));
    const code = await (async () => {
      for await (const _ of gone.reader.follow("bad", new AbortController().signal)) void _;
    })().catch((e: FactoryError) => e.code);
    expect(code).toBe("cursor_gone");
  });
});
