import { describe, expect, it } from "bun:test";
import { createAgwDecider } from "./agw-decider.js";

const BASE_URL = "http://127.0.0.1:7705";
const request = {
  memoId: "0f8fad5b-d9cb-469f-a165-70867728950e",
  state: "kauf bitte Milch",
  destinations: { hermes: "assistant", journal: "diary" },
};
const USAGE = { inputTokens: 90, outputTokens: 0, costUsd: 0.0004 };

interface Call {
  method: string;
  path: string;
  body: unknown;
}

/** `jobs` is the sequence of poll answers; the last one repeats. */
function setup(jobs: { status: string; result?: unknown; error?: string }[], timeoutMs?: number) {
  const calls: Call[] = [];
  const sleeps: number[] = [];
  let polls = 0;
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const path = new URL(String(input)).pathname;
    const method = init?.method ?? "GET";
    calls.push({ method, path, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (method === "POST" && path === "/api/jobs") {
      return Response.json({ ok: true, job: { id: "job-1", status: "pending" } });
    }
    if (method === "POST") return Response.json({ ok: true, job: { id: "job-1" } });
    return Response.json({ ok: true, job: jobs[Math.min(polls++, jobs.length - 1)] });
  }) as typeof fetch;
  const decider = createAgwDecider({
    baseUrl: BASE_URL,
    fetch: fakeFetch,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    ...(timeoutMs !== undefined && { timeoutMs }),
  });
  return { calls, sleeps, decider };
}

const done = (answers: unknown) => ({
  status: "done",
  result: { answers, model: "decider-1", latencyMs: 400, usage: USAGE, truncatedChars: 0 },
});

describe("agw decider", () => {
  it("submits a decide job with a destination question and returns the choice with model and cost", async () => {
    const { calls, decider } = setup([
      { status: "running" },
      done({
        destination: {
          type: "choice",
          choice: "journal",
          confidence: 0.91,
          probabilities: { journal: 0.9, hermes: 0.1 },
        },
      }),
    ]);

    expect(await decider.decide(request)).toEqual({
      destination: { choice: "journal", confidence: 0.91 },
      tab: null,
      model: "decider-1",
      usage: USAGE,
      costUsd: 0.0004,
    });
    const submitted = calls[0]?.body as {
      tool: string;
      caller: string;
      params: { state: string; questions: Record<string, { type: string; options: unknown }> };
    };
    expect(calls[0]).toMatchObject({ method: "POST", path: "/api/jobs" });
    expect(submitted.tool).toBe("decide");
    expect(submitted.caller).toBe("iris");
    expect(submitted.params.state).toBe("kauf bitte Milch");
    expect(Object.keys(submitted.params.questions)).toEqual(["destination"]);
    expect(submitted.params.questions["destination"]).toMatchObject({
      type: "choice",
      options: request.destinations,
    });
  });

  it("adds the tab question when tabs are offered and reads its answer", async () => {
    const { calls, decider } = setup([
      done({
        destination: { type: "choice", choice: "herdr", confidence: 0.9 },
        tab: { type: "choice", choice: "w1:t1", confidence: 0.82 },
      }),
    ]);
    const out = await decider.decide({
      ...request,
      tabs: { "w1:t1": "iris / server", "w2:t1": "dotfiles / 1" },
    });
    const submitted = calls[0]?.body as { params: { questions: Record<string, unknown> } };
    expect(submitted.params.questions["tab"]).toMatchObject({
      type: "choice",
      options: { "w1:t1": "iris / server", "w2:t1": "dotfiles / 1" },
    });
    expect(out.tab).toEqual({ choice: "w1:t1", confidence: 0.82 });
  });

  it("maps a refusal to a null choice and omits cost when the job reports null", async () => {
    const { decider } = setup([
      {
        status: "done",
        result: {
          answers: { destination: { type: "refusal" } },
          model: "decider-1",
          usage: { inputTokens: 5, outputTokens: 0, costUsd: null },
        },
      },
    ]);
    const out = await decider.decide(request);
    expect(out.destination).toBeNull();
    expect("costUsd" in out).toBe(false);
  });

  it("accepts a null usage and omits cost and usage", async () => {
    const { decider } = setup([
      {
        status: "done",
        result: {
          answers: { destination: { type: "choice", choice: "hermes", confidence: 0.9 } },
          model: "decider-1",
          usage: null,
        },
      },
    ]);
    expect(await decider.decide(request)).toEqual({
      destination: { choice: "hermes", confidence: 0.9 },
      tab: null,
      model: "decider-1",
    });
  });

  it("polls every 500 ms and cancels the job at the timeout", async () => {
    const { calls, sleeps, decider } = setup([{ status: "running" }], 1500);
    await expect(decider.decide(request)).rejects.toThrow("agw decide timed out after 1500 ms");
    expect(sleeps).toEqual([500, 500, 500]);
    expect(calls.at(-1)).toMatchObject({ method: "POST", path: "/api/jobs/job-1/cancel" });
  });

  it.each([
    [
      "a confidence outside 0..1",
      done({ destination: { type: "choice", choice: "a", confidence: 1.5 } }),
    ],
    ["no confidence", done({ destination: { type: "choice", choice: "a" } })],
    ["an unknown answer type", done({ destination: { type: "boolean", value: true } })],
    ["no answers", { status: "done", result: { model: "m" } }],
  ])("throws on %s", async (_name, job) => {
    const { decider } = setup([job]);
    await expect(decider.decide(request)).rejects.toThrow("does not match the decision schema");
  });

  it("throws the job error when the job fails", async () => {
    const { decider } = setup([{ status: "failed", error: "model unavailable" }]);
    await expect(decider.decide(request)).rejects.toThrow("agw decide failed: model unavailable");
  });
});
