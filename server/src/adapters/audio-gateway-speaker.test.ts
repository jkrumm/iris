import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import { createAudioGatewaySpeaker } from "./audio-gateway-speaker.js";

const MEMO_ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const MP3 = new Uint8Array([0x49, 0x44, 0x33, 4, 5]);

interface Call {
  url: string;
  init: RequestInit;
}

function setup(respond: () => Response, baseUrl = "http://127.0.0.1:1234") {
  const calls: Call[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond();
  }) as typeof fetch;
  return { calls, speaker: createAudioGatewaySpeaker({ baseUrl, fetch: fakeFetch }) };
}

describe("audio-gateway speaker", () => {
  it("posts the text as an mp3 speech request and returns the audio bytes", async () => {
    const { calls, speaker } = setup(
      () => new Response(MP3, { headers: { "content-type": "audio/mpeg" } }),
    );
    const result = await speaker.speak({ memoId: MEMO_ID, text: "Hallo Welt." });

    expect([...result.bytes]).toEqual([...MP3]);
    expect(calls).toHaveLength(1);
    const call = calls[0] as Call;
    expect(call.url).toBe("http://127.0.0.1:1234/v1/audio/speech");
    expect(call.init.method).toBe("POST");
    expect(call.init.headers).toEqual({
      "content-type": "application/json",
      "x-audio-source": "iris",
    });
    expect(JSON.parse(call.init.body as string)).toEqual({
      input: "Hallo Welt.",
      response_format: "mp3",
    });
    expect(call.init.signal).toBeInstanceOf(AbortSignal);
  });

  it("tolerates a trailing slash on the base URL", async () => {
    const { calls, speaker } = setup(() => new Response(MP3), "http://127.0.0.1:1234//");
    await speaker.speak({ memoId: MEMO_ID, text: "x" });
    expect(calls[0]?.url).toBe("http://127.0.0.1:1234/v1/audio/speech");
  });

  it("fails as unavailable on a non-2xx", async () => {
    const { speaker } = setup(() => new Response("upstream error", { status: 502 }));
    const error = await speaker.speak({ memoId: MEMO_ID, text: "x" }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(MemoError);
    expect(error).toMatchObject({ code: "unavailable", message: "speech synthesis failed: 502" });
  });

  it("fails as unavailable when the gateway returns no audio", async () => {
    const { speaker } = setup(() => new Response(new Uint8Array()));
    await expect(speaker.speak({ memoId: MEMO_ID, text: "x" })).rejects.toMatchObject({
      code: "unavailable",
    });
  });
});
