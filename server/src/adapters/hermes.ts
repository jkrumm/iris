import { z } from "zod";
import type { Delivery, Destination } from "../ports/destination.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";
import { SseIdleError, readSseFrames, type SseFrame } from "./sse.js";

const DEFAULT_IDLE_MS = 300_000;
// Plain request timeout for the quick session POST; the chat turn itself has no wall-clock cap.
const SESSION_TIMEOUT_MS = 30_000;
const ERROR_BODY_MAX = 300;

const AssistantCompleted = z.object({
  content: z.string(),
  partial: z.boolean(),
  interrupted: z.boolean(),
});
const RunCompleted = z.object({
  usage: z
    .object({
      input_tokens: z.number(),
      output_tokens: z.number(),
      total_tokens: z.number(),
    })
    .nullish(),
});
const ErrorEvent = z.object({ message: z.string() });
const ErrorEnvelope = z.object({ error: z.object({ message: z.string().min(1) }) });

export interface HermesDestinationOptions {
  baseUrl: string;
  token: string;
  fetch?: typeof fetch;
  /** Aborts the chat turn when Hermes sends no bytes for this long (default 5 min). */
  idleMs?: number;
}

/** Hermes names a pre-stream failure in an OpenAI error envelope; anything else is truncated. */
async function failureMessage(res: Response): Promise<string> {
  const text = await res.text().catch(() => "");
  try {
    const parsed = ErrorEnvelope.safeParse(JSON.parse(text));
    if (parsed.success) return parsed.data.error.message;
  } catch {
    // not JSON: fall through to the raw body
  }
  return text.slice(0, ERROR_BODY_MAX);
}

function parseData(frame: SseFrame): unknown {
  try {
    return JSON.parse(frame.data);
  } catch {
    throw new Error(`hermes sent invalid JSON in a ${frame.event} event`);
  }
}

/**
 * Delivers a transcript to Hermes: a fresh session named after the memo, one chat turn over
 * the named-event SSE stream, and the final assistant text as the reply.
 */
export function createHermesDestination(opts: HermesDestinationOptions): Destination {
  const doFetch = opts.fetch ?? fetch;
  const idleMs = opts.idleMs ?? DEFAULT_IDLE_MS;
  const headers = {
    Authorization: `Bearer ${opts.token}`,
    "Content-Type": "application/json",
  };

  return {
    async deliver({ memoId, transcript }): Promise<Delivery> {
      const sessionId = memoId;
      const attrs = { memo_id: memoId, downstream: "hermes" };

      await withSpan("hermes.create_session", attrs, async (span) => {
        const res = await doFetch(new URL("/api/sessions", opts.baseUrl).toString(), {
          method: "POST",
          headers,
          body: JSON.stringify({ id: sessionId, source: "iris" }),
          signal: AbortSignal.timeout(SESSION_TIMEOUT_MS),
        });
        span.setAttributes({ status: res.status });
        // 409 session_exists is fine: a retried memo reuses its session.
        if (res.status === 201 || res.status === 409) return;
        throw new Error(`hermes session create failed: ${res.status} ${await failureMessage(res)}`);
      });

      const url = new URL(
        `/api/sessions/${encodeURIComponent(sessionId)}/chat/stream`,
        opts.baseUrl,
      ).toString();

      return withSpan("hermes.chat_stream", attrs, async (span) => {
        // Until the response headers arrive the same idle limit applies, via an abort.
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), idleMs);
        const res = await doFetch(url, {
          method: "POST",
          headers,
          body: JSON.stringify({ message: transcript }),
          signal: controller.signal,
        })
          .catch((err: unknown) => {
            if (controller.signal.aborted)
              throw new Error(`hermes did not respond within ${idleMs} ms`);
            throw err;
          })
          .finally(() => clearTimeout(timer));
        span.setAttributes({ status: res.status });
        if (res.status !== 200 || !res.body) {
          throw new Error(`hermes chat failed: ${res.status} ${await failureMessage(res)}`);
        }

        let reply: { content: string; interrupted: boolean } | null = null;
        let usage: { inputTokens: number; outputTokens: number; totalTokens: number } | undefined;
        let sawDone = false;

        try {
          for await (const frame of readSseFrames(res.body, { idleMs })) {
            if (frame.event === "assistant.completed") {
              const completed = AssistantCompleted.safeParse(parseData(frame));
              if (completed.success && !completed.data.partial) reply = completed.data;
            } else if (frame.event === "run.completed") {
              const completed = RunCompleted.safeParse(parseData(frame));
              const u = completed.success ? completed.data.usage : null;
              if (u) {
                usage = {
                  inputTokens: u.input_tokens,
                  outputTokens: u.output_tokens,
                  totalTokens: u.total_tokens,
                };
              }
            } else if (frame.event === "error") {
              const failed = ErrorEvent.safeParse(parseData(frame));
              throw new Error(`hermes error: ${failed.success ? failed.data.message : frame.data}`);
            } else if (frame.event === "done") {
              sawDone = true;
              break;
            }
          }
        } catch (err) {
          if (err instanceof SseIdleError)
            throw new Error(`hermes stream idle for ${idleMs} ms`, { cause: err });
          throw err;
        }

        if (!sawDone) throw new Error("hermes stream ended without done");
        if (reply?.interrupted) throw new Error("hermes reply was interrupted");

        log("hermes.delivered", { memo_id: memoId, reply_chars: reply?.content.length ?? 0 });
        return {
          ref: sessionId,
          replyText: reply?.content ?? "",
          ...(usage ? { usage } : {}),
        };
      });
    },
  };
}
