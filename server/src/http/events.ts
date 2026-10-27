import { Elysia } from "elysia";
import { isResultReady } from "../memo/memo.js";
import type { MemoService } from "../memo/service.js";
import type { deviceAuth } from "./auth.js";
import { eventJson } from "./serialize.js";

const DEFAULT_KEEPALIVE_MS = 15_000;

const noop = () => {};

/**
 * `GET /events`: one `memo.updated` event per MemoEvent, followed by `memo.done` when the new
 * state is result-ready, plus a keepalive comment. There is no
 * replay: a reconnecting client refetches the list. Unsubscribe and timer cleanup run exactly
 * once, whether the client cancels the stream or the request aborts.
 */
export function eventRoutes(params: {
  memos: MemoService;
  auth: ReturnType<typeof deviceAuth>;
  keepaliveMs?: number | undefined;
}) {
  const { memos, auth, keepaliveMs = DEFAULT_KEEPALIVE_MS } = params;
  const encoder = new TextEncoder();

  return new Elysia().use(auth).get("/events", ({ request, server }) => {
    // SSE is idle by design; the keepalive, not Bun's idle timeout, decides when it is dead.
    server?.timeout(request, 0);
    let cleanup: () => void = noop;

    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        let closed = false;
        const send = (chunk: string) => {
          if (closed) return;
          try {
            controller.enqueue(encoder.encode(chunk));
          } catch {
            cleanup();
          }
        };
        const unsubscribe = memos.subscribe((event) => {
          const data = JSON.stringify(eventJson(event));
          send(`event: memo.updated\ndata: ${data}\n\n`);
          if (isResultReady(event.state) && !event.flagChange)
            send(`event: memo.done\ndata: ${data}\n\n`);
        });
        const timer = setInterval(() => send(": keepalive\n\n"), keepaliveMs);
        cleanup = () => {
          if (closed) return;
          closed = true;
          unsubscribe();
          clearInterval(timer);
          request.signal.removeEventListener("abort", cleanup);
          try {
            controller.close();
          } catch {
            // already closed by a client cancel
          }
        };
        request.signal.addEventListener("abort", cleanup, { once: true });
        if (request.signal.aborted) return cleanup();
        send("event: ready\ndata: {}\n\n");
      },
      cancel: () => cleanup(),
    });

    return new Response(body, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        "x-accel-buffering": "no",
      },
    });
  });
}
