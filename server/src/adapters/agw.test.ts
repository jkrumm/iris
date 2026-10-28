import { describe, expect, it } from "bun:test";
import { z } from "zod";
import { transientKind } from "../ports/transient.js";
import { SUMMARY_JSON_SCHEMA, buildPrompt, createAgwSummarizer } from "./agw.js";

const MEMO_ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const BASE_URL = "http://127.0.0.1:7705";
const SUMMARY = { headline: "Milk", detail: "Buy milk tomorrow.", spoken: "Remember the milk." };
const params = { memoId: MEMO_ID, route: "hermes", transcript: "buy milk", replyText: "Noted." };

interface Call {
  method: string;
  path: string;
  body: unknown;
}

type Job = { status: string; result?: unknown; error?: string | null };

/** A poll answer: a job, a 503, or a network failure (the 15 s request timeout looks the same). */
type PollAnswer = Job | "http-error" | "network-error";

/** `jobs` is the sequence of poll answers; the last one repeats. */
function setup(opts: {
  jobs: PollAnswer[];
  submit?: () => Response;
  baseUrl?: string;
  timeoutMs?: number;
}) {
  const calls: Call[] = [];
  const sleeps: number[] = [];
  let polls = 0;
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const path = new URL(String(input)).pathname;
    const method = init?.method ?? "GET";
    calls.push({ method, path, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (method === "POST" && path === "/api/jobs") {
      return (
        opts.submit?.() ?? Response.json({ ok: true, job: { id: "job-1", status: "pending" } })
      );
    }
    if (method === "POST" && path === "/api/jobs/job-1/cancel") {
      return Response.json({ ok: true, job: { id: "job-1", status: "cancelled" } });
    }
    const job = opts.jobs[Math.min(polls++, opts.jobs.length - 1)];
    if (job === "network-error") throw new Error("request timed out");
    if (job === "http-error") return new Response("bad gateway", { status: 503 });
    return Response.json({ ok: true, job });
  }) as typeof fetch;
  const summarizer = createAgwSummarizer({
    baseUrl: opts.baseUrl ?? BASE_URL,
    fetch: fakeFetch,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    ...(opts.timeoutMs !== undefined ? { timeoutMs: opts.timeoutMs } : {}),
  });
  return { calls, sleeps, summarizer };
}

const submitFailureKind = async (status: number) =>
  transientKind(
    await setup({ jobs: [], submit: () => new Response("x", { status }) })
      .summarizer.summarize(params)
      .catch((e: unknown) => e),
  );

describe("agw summarizer", () => {
  it("submits the triage job, polls until done and returns the summary with usage and cost", async () => {
    const usage = { inputTokens: 100, outputTokens: 20, totalTokens: 120, costUsd: 0.0012 };
    const { calls, sleeps, summarizer } = setup({
      jobs: [
        { status: "pending" },
        { status: "running" },
        {
          status: "done",
          result: { result: SUMMARY, model: "m", latencyMs: 900, usage, attempts: 1 },
        },
      ],
    });

    const out = await summarizer.summarize(params);

    expect(out).toEqual({ summary: SUMMARY, usage, costUsd: 0.0012 });
    expect(sleeps).toEqual([1000, 1000]);
    expect(calls.map((c) => `${c.method} ${c.path}`)).toEqual([
      "POST /api/jobs",
      "GET /api/jobs/job-1",
      "GET /api/jobs/job-1",
      "GET /api/jobs/job-1",
    ]);
    const submitted = calls[0]?.body as {
      tool: string;
      caller: string;
      params: { prompt: string; schema: unknown };
    };
    expect(submitted.tool).toBe("triage");
    expect(submitted.caller).toBe("iris");
    expect(submitted.params.schema).toEqual(SUMMARY_JSON_SCHEMA);
    expect(submitted.params.prompt).toContain("buy milk");
    expect(submitted.params.prompt).toContain("Noted.");
  });

  it("omits costUsd when the job reports null and usage when it reports none", async () => {
    const withNull = setup({
      jobs: [
        {
          status: "done",
          result: { result: SUMMARY, usage: { inputTokens: 1, costUsd: null }, attempts: 1 },
        },
      ],
    });
    const a = await withNull.summarizer.summarize(params);
    expect("costUsd" in a).toBe(false);
    expect(a.usage).toEqual({ inputTokens: 1, costUsd: null });

    const without = setup({ jobs: [{ status: "done", result: { result: SUMMARY } }] });
    const b = await without.summarizer.summarize(params);
    expect(b).toEqual({ summary: SUMMARY });
  });

  it("tolerates a trailing slash on the base URL", async () => {
    const { calls, summarizer } = setup({
      baseUrl: `${BASE_URL}/`,
      jobs: [{ status: "done", result: { result: SUMMARY } }],
    });
    await summarizer.summarize(params);
    expect(calls[0]?.path).toBe("/api/jobs");
  });

  it.each([
    ["headline too long", { ...SUMMARY, headline: "h".repeat(61) }],
    ["detail too long", { ...SUMMARY, detail: "d".repeat(241) }],
    ["spoken too long", { ...SUMMARY, spoken: "s".repeat(301) }],
    ["spoken missing", { headline: "a", detail: "b" }],
  ])("throws on a schema mismatch (%s)", async (_name, result) => {
    const { summarizer } = setup({ jobs: [{ status: "done", result: { result } }] });
    await expect(summarizer.summarize(params)).rejects.toThrow("does not match the summary schema");
  });

  it.each(["failed", "interrupted", "cancelled"])("throws the job error on %s", async (status) => {
    const { summarizer } = setup({ jobs: [{ status, error: "model unavailable" }] });
    await expect(summarizer.summarize(params)).rejects.toThrow(
      `agw triage ${status}: model unavailable`,
    );
  });

  it("cancels the job best effort and throws on timeout", async () => {
    const { calls, sleeps, summarizer } = setup({
      jobs: [{ status: "running" }],
      timeoutMs: 3000,
    });
    await expect(summarizer.summarize(params)).rejects.toThrow("timed out after 3000 ms");
    expect(sleeps).toEqual([1000, 1000, 1000]);
    expect(calls.at(-1)).toEqual({
      method: "POST",
      path: "/api/jobs/job-1/cancel",
      body: undefined,
    });
  });

  it("fails the hang guard for good: not a transient error", async () => {
    const { summarizer } = setup({ jobs: [{ status: "running" }], timeoutMs: 1000 });
    const err = await summarizer.summarize(params).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(Error);
    expect(transientKind(err)).toBeNull();
  });

  it("still reports the timeout when the cancel call fails", async () => {
    const summarizer = createAgwSummarizer({
      baseUrl: BASE_URL,
      timeoutMs: 1000,
      sleep: async () => {},
      fetch: (async (input: string | URL | Request, init?: RequestInit) => {
        const path = new URL(String(input)).pathname;
        if (init?.method === "POST" && path === "/api/jobs") {
          return Response.json({ ok: true, job: { id: "job-1" } });
        }
        if (path.endsWith("/cancel")) throw new Error("connection refused");
        return Response.json({ ok: true, job: { status: "running" } });
      }) as typeof fetch,
    });
    await expect(summarizer.summarize(params)).rejects.toThrow("timed out after 1000 ms");
  });

  it("tolerates transient poll errors and resets the budget on success", async () => {
    const done = { status: "done", result: { result: SUMMARY } };
    const { calls, sleeps, summarizer } = setup({
      jobs: [
        "http-error",
        "network-error",
        { status: "running" },
        "http-error",
        "network-error",
        done,
      ],
    });
    expect((await summarizer.summarize(params)).summary).toEqual(SUMMARY);
    expect(sleeps).toHaveLength(5);
    expect(calls.some((c) => c.path.endsWith("/cancel"))).toBe(false);
  });

  it.each(["http-error", "network-error"] as const)(
    "cancels the job and throws after 3 consecutive poll errors (%s)",
    async (kind) => {
      const { calls, summarizer } = setup({ jobs: [kind] });
      await expect(summarizer.summarize(params)).rejects.toThrow(
        "agw poll failed 3 times in a row, job job-1 cancelled",
      );
      expect(calls.map((c) => `${c.method} ${c.path}`)).toEqual([
        "POST /api/jobs",
        "GET /api/jobs/job-1",
        "GET /api/jobs/job-1",
        "GET /api/jobs/job-1",
        "POST /api/jobs/job-1/cancel",
      ]);
    },
  );

  it("does not cancel on a schema mismatch or a failed job", async () => {
    for (const job of [
      { status: "done", result: { result: { headline: "x" } } },
      { status: "failed", error: "boom" },
    ]) {
      const { calls, summarizer } = setup({ jobs: [job] });
      await expect(summarizer.summarize(params)).rejects.toThrow();
      expect(calls.some((c) => c.path.endsWith("/cancel"))).toBe(false);
    }
  });

  it("never marks a 5xx or a 4xx submit transient: the gateway may have created the job", async () => {
    expect(await submitFailureKind(503)).toBeNull();
    expect(await submitFailureKind(400)).toBeNull();
  });

  it("fails a submit that timed out after acceptance with one submit and no transient mark", async () => {
    const { calls, summarizer } = setup({
      jobs: [],
      submit: () => {
        throw new DOMException("timed out", "TimeoutError");
      },
    });
    const error = await summarizer.summarize(params).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(Error);
    expect(transientKind(error)).toBeNull();
    expect(calls.filter((c) => c.path === "/api/jobs" && c.method === "POST")).toHaveLength(1);
  });

  it("keeps a submit that never left the machine transient", async () => {
    const { summarizer } = setup({
      jobs: [],
      submit: () => {
        throw Object.assign(new TypeError("fetch failed"), {
          cause: Object.assign(new Error("connect"), { code: "ECONNREFUSED" }),
        });
      },
    });
    const error = await summarizer.summarize(params).catch((e: unknown) => e);
    expect(transientKind(error)).toBe("before_send");
  });

  it("throws with the status and body on a non-2xx submit", async () => {
    const { calls, summarizer } = setup({
      jobs: [],
      submit: () => Response.json({ ok: false, error: "unknown tool: triage" }, { status: 400 }),
    });
    await expect(summarizer.summarize(params)).rejects.toThrow(
      'agw submit failed: 400 {"ok":false,"error":"unknown tool: triage"}',
    );
    expect(calls).toHaveLength(1);
  });
});

describe("summary JSON schema", () => {
  it("is a draft-compatible object schema that z.fromJSONSchema accepts with the same limits", () => {
    const schema: Record<string, unknown> = SUMMARY_JSON_SCHEMA;
    const validator = z.fromJSONSchema(schema as Parameters<typeof z.fromJSONSchema>[0]);
    expect(validator.safeParse(SUMMARY).success).toBe(true);
    expect(validator.safeParse({ ...SUMMARY, headline: "h".repeat(60) }).success).toBe(true);
    expect(validator.safeParse({ ...SUMMARY, headline: "h".repeat(61) }).success).toBe(false);
    expect(validator.safeParse({ ...SUMMARY, detail: "d".repeat(241) }).success).toBe(false);
    expect(validator.safeParse({ ...SUMMARY, spoken: "s".repeat(301) }).success).toBe(false);
    expect(validator.safeParse({ headline: "a", detail: "b" }).success).toBe(false);
  });
});

describe("buildPrompt", () => {
  it("labels the sections, marks the memo as data and caps long excerpts", () => {
    const prompt = buildPrompt({
      route: "hermes",
      transcript: "t".repeat(5000),
      replyText: null,
    });
    expect(prompt).toContain("DATA");
    expect(prompt).toContain("language of the transcript");
    expect(prompt).toContain("## Route\nhermes");
    expect(prompt).toContain("## Assistant reply\n(none)");
    expect(prompt).toContain(`${"t".repeat(4000)}\n[truncated]`);
    expect(prompt).not.toContain("t".repeat(4001));
  });
});
