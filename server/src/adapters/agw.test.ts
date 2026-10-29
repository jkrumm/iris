import { describe, expect, it } from "bun:test";
import { createAgwClient } from "./agw-client.js";
import { createAgwSummarizer } from "./agw.js";

const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000005";
const SUMMARY = {
  headline: "Milch kaufen",
  detail: "Die Einkaufsliste wurde um Milch ergänzt.",
  spoken: "Ich habe Milch auf die Einkaufsliste gesetzt.",
};
const USAGE = {
  inputTokens: 120,
  outputTokens: 40,
  reasoningTokens: 0,
  totalTokens: 160,
  cacheReadTokens: 0,
  costUsd: 0.0012,
};
const params = {
  memoId: "0f8fad5b-d9cb-469f-a165-70867728950e",
  route: "hermes",
  transcript: "Kauf bitte Milch",
  replyText: "Erledigt.",
};

function setup(respond: () => Response) {
  const calls: { url: string; body: unknown }[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: JSON.parse(String(init?.body)) });
    return respond();
  }) as typeof fetch;
  const client = createAgwClient({
    baseUrl: "http://127.0.0.1:7791",
    secret: "s",
    fetch: fakeFetch,
  });
  return { calls, summarizer: createAgwSummarizer({ client }) };
}

const flat = (extra: Record<string, unknown> = {}) =>
  Response.json(
    { ...SUMMARY, model: "triage-1", attempts: 1, latencyMs: 900, usage: USAGE, ...extra },
    { headers: { "agw-run-id": RUN_ID } },
  );

describe("agw summarizer", () => {
  it("posts the raw fields whole and maps the flat answer onto summary, usage and cost", async () => {
    const { calls, summarizer } = setup(() => flat());
    expect(await summarizer.summarize(params)).toEqual({
      summary: SUMMARY,
      usage: USAGE,
      costUsd: 0.0012,
    });
    expect(calls).toEqual([
      {
        url: "http://127.0.0.1:7791/triage",
        body: { destination: "hermes", transcript: "Kauf bitte Milch", reply: "Erledigt." },
      },
    ]);
  });

  it("sends a missing reply as null and a long transcript uncut", async () => {
    const { calls, summarizer } = setup(() => flat());
    const transcript = "x".repeat(10_000);
    await summarizer.summarize({ ...params, transcript, replyText: null });
    expect(calls[0]?.body).toEqual({ destination: "hermes", transcript, reply: null });
  });

  it("stores no cost when the host reports null, never 0", async () => {
    const { summarizer } = setup(() => flat({ usage: { ...USAGE, costUsd: null } }));
    const out = await summarizer.summarize(params);
    expect("costUsd" in out).toBe(false);
    expect(out.usage).toEqual({ ...USAGE, costUsd: null });
  });

  it("accepts a missing usage", async () => {
    const { summarizer } = setup(() => flat({ usage: null }));
    expect(await summarizer.summarize(params)).toEqual({ summary: SUMMARY });
  });

  it.each([
    ["an empty headline", { headline: "" }],
    ["a headline over 60", { headline: "h".repeat(61) }],
    ["a detail over 240", { detail: "d".repeat(241) }],
    ["a spoken over 300", { spoken: "s".repeat(301) }],
  ])("throws on %s", async (_name, extra) => {
    const { summarizer } = setup(() => flat(extra));
    await expect(summarizer.summarize(params)).rejects.toThrow("does not match its schema");
  });

  it("throws on a permanent host error", async () => {
    const { summarizer } = setup(() =>
      Response.json({ code: "INVALID_OUTPUT" }, { status: 502, headers: { "agw-run-id": RUN_ID } }),
    );
    await expect(summarizer.summarize(params)).rejects.toThrow(`502 (run ${RUN_ID})`);
  });
});
