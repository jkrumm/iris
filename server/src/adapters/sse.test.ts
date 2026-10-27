import { describe, expect, it } from "bun:test";
import { SseIdleError, readSseFrames, type SseFrame } from "./sse.js";

function streamOf(chunks: Uint8Array[]): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
}

async function collect(chunks: string[]): Promise<SseFrame[]> {
  const encoder = new TextEncoder();
  const frames: SseFrame[] = [];
  for await (const frame of readSseFrames(streamOf(chunks.map((c) => encoder.encode(c))))) {
    frames.push(frame);
  }
  return frames;
}

describe("readSseFrames", () => {
  it("parses several frames from one chunk", async () => {
    expect(await collect(['event: a\ndata: {"n":1}\n\nevent: b\ndata: {"n":2}\n\n'])).toEqual([
      { event: "a", data: '{"n":1}' },
      { event: "b", data: '{"n":2}' },
    ]);
  });

  it("reassembles a frame split mid-line and between the delimiter newlines", async () => {
    expect(
      await collect(["event: ass", 'istant\ndata: {"x"', ":1}\n", "\nevent: done\ndata: {}\n\n"]),
    ).toEqual([
      { event: "assistant", data: '{"x":1}' },
      { event: "done", data: "{}" },
    ]);
  });

  it("drops keepalive comments, alone or inside a frame", async () => {
    expect(
      await collect([": keepalive\n\n", "event: a\n: note\ndata: 1\n\n", ": keepalive\n\n"]),
    ).toEqual([{ event: "a", data: "1" }]);
  });

  it("handles CRLF delimiters, including a CR/LF pair split across chunks", async () => {
    expect(
      await collect(["event: a\r\ndata: 1\r", "\n\r\n", "event: b\r\ndata: 2\r\n\r\n"]),
    ).toEqual([
      { event: "a", data: "1" },
      { event: "b", data: "2" },
    ]);
  });

  it("joins multi-line data and yields an unterminated trailing frame", async () => {
    expect(await collect(["event: a\ndata: x\ndata: y\n\n", "event: b\ndata: tail"])).toEqual([
      { event: "a", data: "x\ny" },
      { event: "b", data: "tail" },
    ]);
  });

  it("decodes a multi-byte character split across chunks", async () => {
    const bytes = new TextEncoder().encode("event: a\ndata: ü\n\n");
    const cut = bytes.indexOf(0xc3) + 1;
    const frames: SseFrame[] = [];
    for await (const frame of readSseFrames(streamOf([bytes.slice(0, cut), bytes.slice(cut)]))) {
      frames.push(frame);
    }
    expect(frames).toEqual([{ event: "a", data: "ü" }]);
  });

  it("throws SseIdleError when no bytes arrive within idleMs, after delivering earlier frames", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode("event: a\ndata: 1\n\n"));
      },
    });
    const frames: SseFrame[] = [];
    const error = await (async () => {
      for await (const frame of readSseFrames(body, { idleMs: 20 })) frames.push(frame);
    })().catch((e: unknown) => e);
    expect(frames).toEqual([{ event: "a", data: "1" }]);
    expect(error).toBeInstanceOf(SseIdleError);
  });
});
