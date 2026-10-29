import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { captureLogs } from "../memo/test-support.js";
import { transientKind } from "../ports/transient.js";
import { createAudioDoorClient } from "./audio-door-client.js";
import { createAudioDoorTranscriber, ffmpegConcat, type ConcatFn } from "./audio-door.js";

const MEMO_ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const AUDIO = new Uint8Array([1, 2, 3, 4]);
const TOKEN = "door-token-0123456789abcdef0123456789";
const RUN_ID = "0198e5a0-7c1d-7000-8000-000000000001";

interface Call {
  url: string;
  init: RequestInit;
}

const door = (fetch: typeof globalThis.fetch) =>
  createAudioDoorClient({ baseUrl: "http://127.0.0.1:1234/v1", token: TOKEN, fetch });

function setup(respond: () => Response) {
  const calls: Call[] = [];
  const concatCalls: string[][] = [];
  const concat: ConcatFn = async (paths) => {
    concatCalls.push(paths);
    return { bytes: AUDIO, seconds: 12.5 };
  };
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return respond();
  }) as typeof fetch;
  const transcriber = createAudioDoorTranscriber({ client: door(fakeFetch), concat });
  return { calls, concatCalls, transcriber };
}

const params = { memoId: MEMO_ID, segmentPaths: ["/seg/0.m4a", "/seg/1.m4a"] };

describe("audio door transcriber", () => {
  it("concats the segments, posts the multipart form and returns text with the audio seconds", async () => {
    const { calls, concatCalls, transcriber } = setup(() => Response.json({ text: "hello world" }));
    const result = await transcriber.transcribe(params);

    expect(result).toEqual({ text: "hello world", audioSeconds: 12.5 });
    expect(concatCalls).toEqual([["/seg/0.m4a", "/seg/1.m4a"]]);
    expect(calls).toHaveLength(1);
    const call = calls[0] as Call;
    expect(call.url).toBe("http://127.0.0.1:1234/v1/audio/transcriptions");
    expect(call.init.method).toBe("POST");
    expect(call.init.headers).toEqual({ authorization: `Bearer ${TOKEN}` });
    expect(call.init.redirect).toBe("error");
    expect(call.init.signal).toBeInstanceOf(AbortSignal);

    const form = call.init.body as FormData;
    expect(form.get("model")).toBe("voxtral-mini-transcribe-3-0");
    expect(form.get("response_format")).toBe("json");
    expect(form.has("language")).toBe(false);
    const file = form.get("file") as File;
    expect(file.name).toBe("memo.m4a");
    expect(file.type).toBe("audio/mp4");
    expect([...new Uint8Array(await file.arrayBuffer())]).toEqual([...AUDIO]);
  });

  it("records the agw-run-id on the log line", async () => {
    const { transcriber } = setup(() =>
      Response.json({ text: "hi" }, { headers: { "agw-run-id": RUN_ID } }),
    );
    const { lines } = await captureLogs(() => transcriber.transcribe(params));
    expect(lines.find((l) => l["event"] === "audio_door.transcribed")).toMatchObject({
      "agw.run_id": RUN_ID,
      memo_id: MEMO_ID,
    });
  });

  it("sends language only when given", async () => {
    const { calls, transcriber } = setup(() => Response.json({ text: "hallo" }));
    await transcriber.transcribe({ ...params, language: "de" });
    const form = (calls[0] as Call).init.body as FormData;
    expect(form.get("language")).toBe("de");
  });

  it("treats a 401 as final and names the run", async () => {
    const { transcriber } = setup(() =>
      Response.json(
        { error: { message: "unauthorized", type: "invalid_request_error" } },
        { status: 401, headers: { "agw-run-id": RUN_ID } },
      ),
    );
    const error = await transcriber.transcribe(params).catch((e: unknown) => e);
    expect((error as Error).message).toContain(`failed: 401 (run ${RUN_ID})`);
    expect((error as Error).message).toContain("unauthorized");
    expect(transientKind(error)).toBeNull();
  });

  it("throws with the status and a truncated body on a non-2xx", async () => {
    const { transcriber } = setup(() => new Response("y".repeat(1000), { status: 502 }));
    const error = await transcriber.transcribe(params).catch((e: Error) => e);
    expect((error as Error).message).toBe(
      `audio door transcription failed: 502 ${"y".repeat(300)}`,
    );
  });

  it("marks a 5xx and a lost connection transient, a 4xx final", async () => {
    const kind = async (respond: () => Response) =>
      transientKind(
        await setup(respond)
          .transcriber.transcribe(params)
          .catch((e: unknown) => e),
      );
    expect(await kind(() => new Response("down", { status: 502 }))).toBe("after_send");
    expect(await kind(() => new Response("no", { status: 400 }))).toBeNull();
    expect(await kind(() => new Response("big", { status: 413 }))).toBeNull();
    const refused = Object.assign(new TypeError("fetch failed"), {
      cause: Object.assign(new Error("connect"), { code: "ECONNREFUSED" }),
    });
    const gone = setup(() => {
      throw refused;
    }).transcriber;
    expect(transientKind(await gone.transcribe(params).catch((e: unknown) => e))).toBe(
      "before_send",
    );
  });

  it("fails after one window when the gateway hangs past the timeout, not transient", async () => {
    let attempts = 0;
    const hangs = (async (_input: string | URL | Request, init?: RequestInit) => {
      attempts++;
      await new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
      });
    }) as unknown as typeof fetch;
    const transcriber = createAudioDoorTranscriber({
      client: door(hangs),
      concat: async () => ({ bytes: AUDIO, seconds: 1 }),
      timeoutMs: 20,
    });
    const error = await transcriber.transcribe(params).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toBe("audio door transcription timed out after 20 ms");
    expect(transientKind(error)).toBeNull();
    expect(attempts).toBe(1);
  });

  it("fails after one window when the timeout hits while the body is read, not transient", async () => {
    const timedOut = new DOMException("The operation timed out.", "TimeoutError");
    const stalled = new ReadableStream({
      start(controller) {
        controller.error(timedOut);
      },
    });
    const { calls, transcriber } = setup(() => new Response(stalled, { status: 200 }));
    const error = await transcriber.transcribe(params).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toBe("audio door transcription timed out after 1800000 ms");
    expect(transientKind(error)).toBeNull();
    expect(calls).toHaveLength(1);
  });

  it("calls a 413 terminal", async () => {
    const { transcriber } = setup(() =>
      Response.json({ error: { message: "too many chunks" } }, { status: 413 }),
    );
    await expect(transcriber.transcribe(params)).rejects.toThrow(/413 is terminal/);
  });

  it("fails final and names the cause when a 200 body is not JSON", async () => {
    const { transcriber } = setup(() => new Response("<html>not json</html>", { status: 200 }));
    const error = await transcriber.transcribe(params).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toContain("audio door transcription response is unreadable");
    expect(transientKind(error)).toBeNull();
  });

  it("calls a body cut off by a lost connection transient", async () => {
    const reset = new ReadableStream({
      start(controller) {
        controller.error(Object.assign(new Error("socket closed"), { code: "ECONNRESET" }));
      },
    });
    const { transcriber } = setup(() => new Response(reset, { status: 200 }));
    const error = await transcriber.transcribe(params).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(Error);
    expect(transientKind(error)).toBe("after_send");
  });

  it("throws when the response carries no text", async () => {
    const { transcriber } = setup(() => Response.json({ nope: true }));
    await expect(transcriber.transcribe(params)).rejects.toThrow("no text field");
  });

  it("does not call the door when the concat fails", async () => {
    const calls: string[] = [];
    const transcriber = createAudioDoorTranscriber({
      client: door((async (input: string | URL | Request) => {
        calls.push(String(input));
        return Response.json({ text: "x" });
      }) as typeof fetch),
      concat: async () => {
        throw new Error("segment missing");
      },
    });
    await expect(transcriber.transcribe(params)).rejects.toThrow("segment missing");
    expect(calls).toEqual([]);
  });
});

async function ffmpeg(args: string[]) {
  const proc = Bun.spawn(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", ...args], {
    stdout: "ignore",
    stderr: "pipe",
  });
  const [stderr, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`test ffmpeg failed: ${stderr}`);
}

const concatDirs = async () =>
  (await readdir(tmpdir())).filter((name) => name.startsWith("iris-concat-"));

describe.skipIf(!Bun.which("ffmpeg") || !Bun.which("ffprobe"))("ffmpegConcat (real ffmpeg)", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "iris-seg-"));
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  it("joins two one-second segments into one ~2 s m4a and cleans up", async () => {
    const segments = [join(dir, "0.m4a"), join(dir, "1.m4a")];
    for (const [i, path] of segments.entries()) {
      await ffmpeg([
        "-f",
        "lavfi",
        "-i",
        `sine=frequency=${440 + i * 220}:duration=1`,
        "-c:a",
        "aac",
        path,
      ]);
    }
    const before = await concatDirs();

    const { bytes, seconds } = await ffmpegConcat(segments);

    expect(seconds).toBeGreaterThan(1.8);
    expect(seconds).toBeLessThan(2.4);
    expect(bytes.length).toBeGreaterThan(500);
    // An MP4 container starts with a size box followed by the `ftyp` marker.
    expect(new TextDecoder().decode(bytes.slice(4, 8))).toBe("ftyp");
    // +faststart: the moov atom precedes the media data so the scrubber can stream.
    const text = new TextDecoder("latin1").decode(bytes);
    expect(text.indexOf("moov")).toBeGreaterThan(0);
    expect(text.indexOf("moov")).toBeLessThan(text.indexOf("mdat"));
    expect(await concatDirs()).toEqual(before);
  });

  it("names a missing segment", async () => {
    const missing = join(dir, "nope.m4a");
    await expect(ffmpegConcat([missing])).rejects.toThrow(`segment file missing: ${missing}`);
  });

  it("includes the ffmpeg stderr tail on a non-zero exit and still cleans up", async () => {
    const garbage = join(dir, "garbage.m4a");
    await writeFile(garbage, "this is not audio");
    const before = await concatDirs();

    const error = await ffmpegConcat([garbage]).catch((e: Error) => e);

    expect((error as Error).message).toMatch(/^ffmpeg exited with \d+: .+/s);
    expect(await concatDirs()).toEqual(before);
  });
});
