import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import { captureLogs } from "../memo/test-support.js";
import { transientKind } from "../ports/transient.js";
import { createAudioDoorClient } from "./audio-door-client.js";
import { createAudioDoorSpeaker } from "./audio-door-speaker.js";

const MEMO_ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const TOKEN = "door-token-0123456789abcdef0123456789";
const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000002";
const MP3 = new Uint8Array([0x49, 0x44, 0x33, 4, 5]);

interface Call {
  url: string;
  init: RequestInit;
}

const door = (fetch: typeof globalThis.fetch) =>
  createAudioDoorClient({ baseUrl: "http://127.0.0.1:1234/v1", token: TOKEN, fetch });

function setup(respond: () => Response) {
  const calls: Call[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond();
  }) as typeof fetch;
  return { calls, speaker: createAudioDoorSpeaker({ client: door(fakeFetch) }) };
}

describe("audio door speaker", () => {
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
    expect(call.init.redirect).toBe("error");
    expect(call.init.headers).toEqual({
      "content-type": "application/json",
      authorization: `Bearer ${TOKEN}`,
    });
    expect(JSON.parse(call.init.body as string)).toEqual({
      input: "Hallo Welt.",
      response_format: "mp3",
    });
    expect(call.init.signal).toBeInstanceOf(AbortSignal);
  });

  it("fails as unavailable on a non-2xx", async () => {
    const { speaker } = setup(() => new Response("upstream error", { status: 502 }));
    const error = await speaker.speak({ memoId: MEMO_ID, text: "x" }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(MemoError);
    expect(error).toMatchObject({ code: "unavailable", message: "speech synthesis failed: 502" });
  });

  it("fails as unavailable, not transient, on a 401 and logs the run id", async () => {
    const { speaker } = setup(() =>
      Response.json(
        { error: { message: "unauthorized" } },
        { status: 401, headers: { "agw-run-id": RUN_ID } },
      ),
    );
    const { result: error, lines } = await captureLogs(() =>
      speaker.speak({ memoId: MEMO_ID, text: "x" }).catch((e: unknown) => e),
    );
    expect(error).toMatchObject({ code: "unavailable", message: "speech synthesis failed: 401" });
    expect(transientKind(error)).toBeNull();
    expect(lines.find((l) => l["event"] === "audio_door.speak_failed")).toMatchObject({
      status: 401,
      "agw.run_id": RUN_ID,
    });
  });

  it("logs the run id of a successful synthesis", async () => {
    const { speaker } = setup(() => new Response(MP3, { headers: { "agw-run-id": RUN_ID } }));
    const { lines } = await captureLogs(() => speaker.speak({ memoId: MEMO_ID, text: "x" }));
    expect(lines.find((l) => l["event"] === "audio_door.spoke")).toMatchObject({
      "agw.run_id": RUN_ID,
      bytes: MP3.length,
    });
  });

  it("fails as unavailable on a network error", async () => {
    const speaker = createAudioDoorSpeaker({
      client: door((async () => {
        throw new TypeError("fetch failed");
      }) as unknown as typeof fetch),
    });
    const error = await speaker.speak({ memoId: MEMO_ID, text: "x" }).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(MemoError);
    expect(error).toMatchObject({
      code: "unavailable",
      message: "speech synthesis unreachable: fetch failed",
    });
  });

  it("fails as unavailable when the request is aborted or times out", async () => {
    const speaker = createAudioDoorSpeaker({
      client: door((async () => {
        throw new DOMException("The operation timed out.", "TimeoutError");
      }) as unknown as typeof fetch),
    });
    await expect(speaker.speak({ memoId: MEMO_ID, text: "x" })).rejects.toMatchObject({
      code: "unavailable",
    });
  });

  it("fails once, not transient, when the door hangs past the timeout", async () => {
    let attempts = 0;
    const speaker = createAudioDoorSpeaker({
      timeoutMs: 20,
      client: door((async (_input: string | URL | Request, init?: RequestInit) => {
        attempts++;
        await new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), {
            once: true,
          });
        });
      }) as unknown as typeof fetch),
    });
    const error = await speaker.speak({ memoId: MEMO_ID, text: "x" }).catch((e: unknown) => e);
    expect(error).toMatchObject({ code: "unavailable" });
    expect((error as Error).message).toContain("speech synthesis unreachable");
    expect(transientKind(error)).toBeNull();
    expect(attempts).toBe(1);
  });

  it("fails as unavailable when the body stream breaks mid-download", async () => {
    const broken = new ReadableStream({
      start(controller) {
        controller.error(new Error("connection reset"));
      },
    });
    const { speaker } = setup(() => new Response(broken));
    await expect(speaker.speak({ memoId: MEMO_ID, text: "x" })).rejects.toMatchObject({
      code: "unavailable",
      message: "speech synthesis unreachable: connection reset",
    });
  });

  it("fails as unavailable when the door returns no audio", async () => {
    const { speaker } = setup(() => new Response(new Uint8Array()));
    await expect(speaker.speak({ memoId: MEMO_ID, text: "x" })).rejects.toMatchObject({
      code: "unavailable",
    });
  });
});
