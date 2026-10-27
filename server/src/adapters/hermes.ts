import { z } from "zod";
import { threadTitle } from "../memo/memo.js";
import type { Delivery, Destination } from "../ports/destination.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";
import { SseIdleError, readSseFrames, type SseFrame } from "./sse.js";

const DEFAULT_IDLE_MS = 300_000;
// Plain request timeout for the quick session POST; the chat turn itself has no wall-clock cap.
const SESSION_TIMEOUT_MS = 30_000;
const ERROR_BODY_MAX = 300;

/** Hermes session `source` of a normal memo and of a chat. */
const SOURCE_MEMO = "iris";
const SOURCE_CHAT = "iris-chat";

/**
 * Sent as the per-turn `system_message` of every chat turn. Hermes appends it to the session's system prompt for that
 * turn only and does not persist it, so a later reply into the thread must send it again.
 */
export const CHAT_SYSTEM_MESSAGE = [
  "This is a conversation, not a task. Answer conversationally and concisely.",
  "Take NO actions with side effects: make no tool calls that write, send, schedule, create, delete or change anything,",
  "anywhere (files, messages, calendar, notes, tickets, services, settings). Read-only lookups are fine when needed to answer.",
  "If the user asks you to do something that would change state, say what you would do and that this chat cannot do it.",
].join(" ");

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
 * the named-event SSE stream, and the final assistant text as the reply. A chat turn also carries
 * `CHAT_SYSTEM_MESSAGE` and opens its session with `source: "iris-chat"`. Note: the Hermes API server maps a `source` it does
 * not know (today everything but its own platform names) to `api_server`, so the thread's kind is Iris's own record (`threads.kind`), not Hermes's.
 * The delivery names the thread (the session id, its kind and title); `act` only persists it.
 */
export function createHermesDestination(opts: HermesDestinationOptions): Destination {
  const doFetch = opts.fetch ?? fetch;
  const idleMs = opts.idleMs ?? DEFAULT_IDLE_MS;
  const headers = {
    Authorization: `Bearer ${opts.token}`,
    "Content-Type": "application/json",
  };

  return {
    async deliver({ memoId, transcript, chat = false }): Promise<Delivery> {
      const sessionId = memoId;
      const attrs = { memo_id: memoId, downstream: "hermes" };

      await withSpan("hermes.create_session", attrs, async (span) => {
        const res = await doFetch(new URL("/api/sessions", opts.baseUrl).toString(), {
          method: "POST",
          headers,
          body: JSON.stringify({ id: sessionId, source: chat ? SOURCE_CHAT : SOURCE_MEMO }),
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
          body: JSON.stringify({
            message: transcript,
            ...(chat && { system_message: CHAT_SYSTEM_MESSAGE }),
          }),
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
          thread: { id: sessionId, kind: chat ? "chat" : "hermes", title: threadTitle(transcript) },
          ...(usage ? { usage } : {}),
        };
      });
    },
  };
}
