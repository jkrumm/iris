import { Elysia } from "elysia";
import { isResultReady } from "../memo/memo.js";
import type { ReplyProgress } from "../memo/progress.js";
import type { MemoService } from "../memo/service.js";
import { log } from "../telemetry/log.js";
import { recordSpan } from "../telemetry/otel.js";
import type { deviceAuth } from "./auth.js";
import { activityJson, deltaJson, eventJson } from "./serialize.js";

const DEFAULT_KEEPALIVE_MS = 15_000;

const noop = (_reason?: string) => {};

/**
 * `GET /events`: one `memo.updated` event per MemoEvent, followed by `memo.done` when the new
 * state is result-ready, plus a keepalive comment. While `act` runs, the progress bus adds `memo.delta`
 * (the reply text so far, in coalesced pieces with `attempt` and `seq`) and `memo.activity` (a tool Hermes started).
 * There is no replay: a reconnecting client refetches the list (and a memo's `partialReply`). Unsubscribe and timer cleanup run exactly
 * once, whether the client cancels the stream or the request aborts.
 *
 * Telemetry: `sse.opened` (a log line) says how many streams are open now and whether the device has opened one before in this
 * process (a reconnect); `sse.stream` (a span, recorded on close) has the stream's lifetime, the count left open and why it ended.
 * The device name only keys that in-memory memory of reconnects, it is never an attribute.
 */
export function eventRoutes(params: {
  memos: MemoService;
  auth: ReturnType<typeof deviceAuth>;
  progress?: ReplyProgress | undefined;
  keepaliveMs?: number | undefined;
}) {
  const { memos, auth, progress, keepaliveMs = DEFAULT_KEEPALIVE_MS } = params;
  const encoder = new TextEncoder();
  let openStreams = 0;
  const devicesSeen = new Set<string>();

  return new Elysia().use(auth).get("/events", ({ request, server, device }) => {
    // SSE is idle by design; the keepalive, not Bun's idle timeout, decides when it is dead.
    server?.timeout(request, 0);
    let cleanup: (reason?: string) => void = noop;
    const openedAt = performance.now();
    const key = device ?? "";
    const reconnect = devicesSeen.has(key);
    devicesSeen.add(key);
    openStreams++;
    log("sse.opened", { open_streams: openStreams, reconnect });

    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        let closed = false;
        const send = (chunk: string) => {
          if (closed) return;
          try {
            controller.enqueue(encoder.encode(chunk));
          } catch {
            cleanup("write_failed");
          }
        };
        const unsubscribe = memos.subscribe((event) => {
          const data = JSON.stringify(eventJson(event));
          send(`event: memo.updated\ndata: ${data}\n\n`);
          if (isResultReady(event.state) && !event.flagChange)
            send(`event: memo.done\ndata: ${data}\n\n`);
        });
        const unsubscribeProgress = progress?.subscribe((event) => {
          if (event.type === "delta") {
            send(`event: memo.delta\ndata: ${JSON.stringify(deltaJson(event))}\n\n`);
          } else {
            send(`event: memo.activity\ndata: ${JSON.stringify(activityJson(event))}\n\n`);
          }
        });
        const timer = setInterval(() => send(": keepalive\n\n"), keepaliveMs);
        const onAbort = () => cleanup("abort");
        cleanup = (reason = "closed") => {
          if (closed) return;
          closed = true;
          openStreams--;
          recordSpan({
            name: "sse.stream",
            kind: "server",
            durationMs: performance.now() - openedAt,
            attrs: { open_streams: openStreams, reconnect, close_reason: reason },
          });
          unsubscribe();
          unsubscribeProgress?.();
          clearInterval(timer);
          request.signal.removeEventListener("abort", onAbort);
          try {
            controller.close();
          } catch {
            // already closed by a client cancel
          }
        };
        request.signal.addEventListener("abort", onAbort, { once: true });
        if (request.signal.aborted) return cleanup("abort");
        send("event: ready\ndata: {}\n\n");
      },
      cancel: () => cleanup("cancel"),
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
