import { describe, expect, it } from "bun:test";
import { createAudioDoorClient } from "./audio-door-client.js";

const TOKEN = "door-token-0123456789abcdef0123456789";
const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000003";

function setup(respond: () => Response, baseUrl = "http://127.0.0.1:1234/v1") {
  const calls: { url: string; init: RequestInit }[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond();
  }) as typeof fetch;
  return { calls, client: createAudioDoorClient({ baseUrl, token: TOKEN, fetch: fakeFetch }) };
}

describe("audio door client", () => {
  it("posts under the base with the bearer, a hang guard and no redirects", async () => {
    const { calls, client } = setup(() => new Response("ok"));
    await client.post({
      path: "/audio/speech",
      body: "{}",
      headers: { "content-type": "application/json" },
      timeoutMs: 1000,
    });

    const call = calls[0];
    expect(call?.url).toBe("http://127.0.0.1:1234/v1/audio/speech");
    expect(call?.init.method).toBe("POST");
    expect(call?.init.headers).toEqual({
      "content-type": "application/json",
      authorization: `Bearer ${TOKEN}`,
    });
    expect(call?.init.redirect).toBe("error");
    expect(call?.init.signal).toBeInstanceOf(AbortSignal);
  });

  it("tolerates trailing slashes on the base URL", async () => {
    const { calls, client } = setup(() => new Response("ok"), "http://127.0.0.1:1234/v1//");
    await client.post({ path: "/audio/transcriptions", body: "x", timeoutMs: 1000 });
    expect(calls[0]?.url).toBe("http://127.0.0.1:1234/v1/audio/transcriptions");
  });

  it("returns the agw-run-id of the answer, null when absent", async () => {
    const withId = setup(() => new Response("ok", { headers: { "agw-run-id": RUN_ID } }));
    expect((await withId.client.post({ path: "/x", body: "x", timeoutMs: 1000 })).runId).toBe(
      RUN_ID,
    );
    const without = setup(() => new Response("ok"));
    expect(
      (await without.client.post({ path: "/x", body: "x", timeoutMs: 1000 })).runId,
    ).toBeNull();
  });

  it("keeps a caller header from replacing the bearer", async () => {
    const { calls, client } = setup(() => new Response("ok"));
    await client.post({
      path: "/x",
      body: "x",
      headers: { authorization: "Bearer other" },
      timeoutMs: 1000,
    });
    expect(calls[0]?.init.headers).toEqual({ authorization: `Bearer ${TOKEN}` });
  });
});
