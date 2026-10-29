import { describe, expect, it } from "bun:test";
import { createAgwClient } from "./agw-client.js";
import { createAgwDecider } from "./agw-decider.js";

const BASE_URL = "http://127.0.0.1:7791";
const request = {
  memoId: "0f8fad5b-d9cb-469f-a165-70867728950e",
  state: "kauf bitte Milch",
  destinations: { hermes: "assistant", journal: "diary" },
};
const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000006";
const USAGE = { inputTokens: 90, outputTokens: 0, costUsd: 0.0004 };

interface Call {
  path: string;
  body: unknown;
}

function setup(respond: () => Response) {
  const calls: Call[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ path: new URL(String(input)).pathname, body: JSON.parse(String(init?.body)) });
    return respond();
  }) as typeof fetch;
  const client = createAgwClient({ baseUrl: BASE_URL, secret: "s", fetch: fakeFetch });
  return { calls, decider: createAgwDecider({ client }) };
}

const answered =
  (answers: unknown, extra: Record<string, unknown> = {}) =>
  () =>
    Response.json(
      {
        answers,
        model: "decision-1-eu",
        truncatedChars: 0,
        latencyMs: 400,
        usage: USAGE,
        ...extra,
      },
      { headers: { "agw-run-id": RUN_ID } },
    );

describe("agw decider", () => {
  it("posts a destination question and returns the choice with model and cost", async () => {
    const { calls, decider } = setup(
      answered({
        destination: {
          type: "choice",
          choice: "journal",
          confidence: 0.91,
          probabilities: { journal: 0.9, hermes: 0.1 },
        },
      }),
    );

    expect(await decider.decide(request)).toEqual({
      destination: { choice: "journal", confidence: 0.91 },
      tab: null,
      model: "decision-1-eu",
      usage: USAGE,
      costUsd: 0.0004,
    });
    const body = calls[0]?.body as {
      caller?: string;
      state: string;
      questions: Record<string, { type: string; options: unknown }>;
    };
    expect(calls[0]?.path).toBe("/decide");
    expect(body.caller).toBeUndefined();
    expect(body.state).toBe("kauf bitte Milch");
    expect(Object.keys(body.questions)).toEqual(["destination"]);
    expect(body.questions["destination"]).toMatchObject({
      type: "choice",
      options: request.destinations,
    });
  });

  it("adds the tab question when tabs are offered and reads its answer", async () => {
    const { calls, decider } = setup(
      answered({
        destination: { type: "choice", choice: "herdr", confidence: 0.9 },
        tab: { type: "choice", choice: "w1:t1", confidence: 0.82 },
      }),
    );
    const out = await decider.decide({
      ...request,
      tabs: { "w1:t1": "iris / server", "w2:t1": "dotfiles / 1" },
    });
    const body = calls[0]?.body as { questions: Record<string, unknown> };
    expect(body.questions["tab"]).toMatchObject({
      type: "choice",
      options: { "w1:t1": "iris / server", "w2:t1": "dotfiles / 1" },
    });
    expect(out.tab).toEqual({ choice: "w1:t1", confidence: 0.82 });
  });

  it("maps a refusal to a null choice and omits cost when the host reports null", async () => {
    const { decider } = setup(
      answered(
        { destination: { type: "refusal" } },
        { usage: { inputTokens: 5, outputTokens: 0, costUsd: null } },
      ),
    );
    const out = await decider.decide(request);
    expect(out.destination).toBeNull();
    expect("costUsd" in out).toBe(false);
  });

  it("accepts a null usage and omits cost and usage", async () => {
    const { decider } = setup(
      answered(
        { destination: { type: "choice", choice: "hermes", confidence: 0.9 } },
        { usage: null },
      ),
    );
    expect(await decider.decide(request)).toEqual({
      destination: { choice: "hermes", confidence: 0.9 },
      tab: null,
      model: "decision-1-eu",
    });
  });

  it.each([
    [
      "a confidence outside 0..1",
      answered({ destination: { type: "choice", choice: "a", confidence: 1.5 } }),
    ],
    ["no confidence", answered({ destination: { type: "choice", choice: "a" } })],
    ["an unknown answer type", answered({ destination: { type: "boolean", value: true } })],
    ["no answers", () => Response.json({ model: "m" })],
  ])("throws on %s", async (_name, respond) => {
    const { decider } = setup(respond);
    await expect(decider.decide(request)).rejects.toThrow("does not match its schema");
  });

  it("throws on a host error and names the run", async () => {
    const { decider } = setup(() =>
      Response.json({ code: "BAD_REQUEST" }, { status: 400, headers: { "agw-run-id": RUN_ID } }),
    );
    await expect(decider.decide(request)).rejects.toThrow(
      `agw decide failed: 400 BAD_REQUEST (run ${RUN_ID})`,
    );
  });
});
