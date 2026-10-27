export interface SseFrame {
  event: string;
  data: string;
}

function parseBlock(block: string): SseFrame | null {
  let event = "message";
  const data: string[] = [];
  for (const line of block.split("\n")) {
    if (line === "" || line.startsWith(":")) continue;
    if (line.startsWith("event:")) event = line.slice(6).trim();
    else if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
  }
  return data.length === 0 ? null : { event, data: data.join("\n") };
}

export class SseIdleError extends Error {
  constructor(readonly idleMs: number) {
    super(`no bytes received for ${idleMs} ms`);
    this.name = "SseIdleError";
  }
}

/** Rejects with `SseIdleError` when `read` does not settle within `idleMs`. */
function withIdleTimeout<T>(read: Promise<T>, idleMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const idle = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new SseIdleError(idleMs)), idleMs);
  });
  return Promise.race([read, idle]).finally(() => clearTimeout(timer));
}

/**
 * Yields the `event:`/`data:` frames of an SSE body. Frames may be split across chunks and
 * comment-only frames (`: keepalive`) are dropped. A trailing frame without its blank line is
 * still yielded when the stream ends. Leaving the loop early cancels the underlying stream. With
 * `idleMs`, a read that gets no bytes (keepalive comments count as bytes) for that long throws
 * `SseIdleError`; time the consumer spends between frames does not count.
 */
export async function* readSseFrames(
  body: ReadableStream<Uint8Array>,
  opts: { idleMs?: number } = {},
): AsyncGenerator<SseFrame> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    for (;;) {
      const { done, value } = await (opts.idleMs === undefined
        ? reader.read()
        : withIdleTimeout(reader.read(), opts.idleMs));
      if (done) break;
      // CR is stripped so both `\n\n` and `\r\n\r\n` delimit frames, even when split across chunks.
      buffer += decoder.decode(value, { stream: true }).replace(/\r/g, "");
      for (let idx = buffer.indexOf("\n\n"); idx !== -1; idx = buffer.indexOf("\n\n")) {
        const frame = parseBlock(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 2);
        if (frame) yield frame;
      }
    }
    buffer += decoder.decode().replace(/\r/g, "");
    const tail = parseBlock(buffer);
    if (tail) yield tail;
  } finally {
    await reader.cancel().catch(() => {});
  }
}
