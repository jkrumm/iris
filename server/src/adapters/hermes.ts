import { z } from "zod";
import {
  clipCodePoints,
  HEADLINE_MAX,
  normalizeActions,
  normalizeKind,
  threadTitle,
  type MemoMode,
} from "../memo/memo.js";
import type { Delivery, DeliveryMeta, Destination } from "../ports/destination.js";
import { fetchFailure, hangGuardFailure, httpFailure } from "../ports/transient.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";
import { SseIdleError, readSseFrames, type SseFrame } from "./sse.js";

const DEFAULT_IDLE_MS = 300_000;
// Plain request timeout for the quick session POST; the chat turn itself has no wall-clock cap.
const SESSION_TIMEOUT_MS = 30_000;
const ERROR_BODY_MAX = 300;

/** The `source` of every Iris session. */
const SOURCE = "iris";

/**
 * Sent as the per-turn `system_message` of every turn, new session or continuation: Hermes appends it to the session's system
 * prompt for that turn only and does not persist it, so each reply into a thread sends it again. It names the Iris turn and the
 * `iris` skill's contract (the reply ends in one ```iris block, `parseIrisBlock`). Hermes folds an unknown `source` into
 * `api_server`, so this message, not the source, is what tells it the turn comes from Iris.
 */
export const IRIS_SYSTEM_MESSAGE =
  "This turn comes from Iris: the message is a transcript of the owner's voice memo (German or English, speech-to-text errors likely). Load skill_view('iris') and follow it: decide what the memo is, act with your skills (a side effect only when the memo asks for one), and end your reply with exactly one ```iris block.";

/** What the owner picked in an older app build, as one extra line; `auto` and `hermes` pick nothing. */
const PICKED: Partial<Record<MemoMode, string>> = {
  chat: "Chat.",
  journal: "Journal.",
  tab: "Tab.",
};

/** The `system_message` of a turn in `mode`. */
export function systemMessage(mode: MemoMode): string {
  const picked = PICKED[mode];
  return picked === undefined
    ? IRIS_SYSTEM_MESSAGE
    : `${IRIS_SYSTEM_MESSAGE}\nThe owner picked: ${picked}`;
}

// Extra keys (an old `spoken`) are ignored: the spoken line and the summary are triage's (`summarize`), not Hermes's.
const IrisBlock = z.object({ kind: z.string(), headline: z.string() });

// The tag must stand alone (not ```irisfoo); the block may start on the next line or right after the tag on one line.
const IRIS_FENCE = /```iris(?=[\s{])[ \t]*\r?\n?([\s\S]*?)```/g;

export interface IrisBlockResult {
  /** The reply without the last ```iris fence and the whitespace before it. */
  reply: string;
  /** Null when there was no valid block; `invalid` then says why (never the content). */
  meta: { kind: string | null; headline: string | null } | null;
  invalid?: string;
}

/**
 * Takes the last ```iris fence of the final reply: parsed leniently (extra keys ignored; no fence, bad JSON or a missing key is
 * "no block"), and cut out of the reply either way, since a machine block is never the answer. `kind` is normalised
 * (`normalizeKind`), the headline clipped to `HEADLINE_MAX`; a blank headline is none, so `notify` falls back to the transcript.
 */
export function parseIrisBlock(reply: string): IrisBlockResult {
  const fences = [...reply.matchAll(IRIS_FENCE)];
  const last = fences.at(-1);
  if (!last || last.index === undefined) return { reply, meta: null, invalid: "missing_block" };
  const before = reply.slice(0, last.index).trimEnd();
  const stripped = `${before}${reply.slice(last.index + last[0].length)}`.trimEnd();

  let json: unknown;
  try {
    json = JSON.parse(last[1] ?? "");
  } catch {
    return { reply: stripped, meta: null, invalid: "invalid_json" };
  }
  const parsed = IrisBlock.safeParse(json);
  if (!parsed.success) {
    const keys = [...new Set(parsed.error.issues.map((issue) => issue.path.join(".") || "(root)"))];
    return { reply: stripped, meta: null, invalid: `invalid_shape: ${keys.join(", ")}` };
  }
  const headline = clipCodePoints(parsed.data.headline.trim(), HEADLINE_MAX);
  return {
    reply: stripped,
    meta: {
      kind: normalizeKind(parsed.data.kind),
      headline: headline === "" ? null : headline,
    },
  };
}

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
// `tool.started` frames carry the tool's name and its arguments at the top level (hermes-agent `gateway/platforms/api_server.py`,
// `_tool_progress`). The arguments are read for one tool only: `skill_view`, whose `name` is the skill Hermes loaded.
const ToolStarted = z.object({ tool_name: z.string(), args: z.unknown().optional() });

/** The skill whose load every Iris turn starts with: not something Hermes did for the memo. */
const IRIS_SKILL = "iris";

/**
 * What a `tool.started` frame adds to `actions`: the tool's name, except for `skill_view` (hermes-agent `tools/skills_tool.py`
 * `skill_view(name, file_path, …)`), where it is the loaded skill's name (`args.name`, a string only; a `<plugin>:` prefix and any
 * path are cut to the last segment) and the `iris` skill itself or a call without a usable name adds nothing. Never any other
 * argument.
 */
export function actionOf(frame: { tool_name: string; args?: unknown }): string | null {
  if (frame.tool_name !== "skill_view") return frame.tool_name;
  const { args } = frame;
  const name =
    typeof args === "object" && args !== null ? (args as { name?: unknown }).name : undefined;
  if (typeof name !== "string") return null;
  const skill = name.split(":").at(-1)?.split("/").at(-1)?.trim() ?? "";
  return skill === "" || skill === IRIS_SKILL ? null : skill;
}
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
async function failureMessage(res: Response, signal: AbortSignal): Promise<string> {
  // Bounded by `signal`: a body that stalls after its headers must not hang the turn. A cut-off body is no message.
  const aborted = new Promise<string>((resolve) => {
    if (signal.aborted) resolve("");
    signal.addEventListener("abort", () => resolve(""), { once: true });
  });
  const text = await Promise.race([res.text().catch(() => ""), aborted]);
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

const SHAPE_EVENT_MAX_CHARS = 40;
const SHAPE_EVENT_MAX_NAMES = 30;

/**
 * Collects what the stream looked like, never what it said: per event name the frame count and the union of the top-level
 * key names of its JSON-object data. Event names come from the wire, so they are clipped and capped.
 */
function frameShape() {
  // Maps, not objects: event names come from the wire (`constructor`, `__proto__`).
  const counts = new Map<string, number>();
  const keySets = new Map<string, Set<string>>();
  return {
    add(frame: SseFrame): void {
      const name = frame.event.slice(0, SHAPE_EVENT_MAX_CHARS);
      if (!counts.has(name) && counts.size >= SHAPE_EVENT_MAX_NAMES) return;
      counts.set(name, (counts.get(name) ?? 0) + 1);
      let data: unknown;
      try {
        data = JSON.parse(frame.data);
      } catch {
        return;
      }
      if (typeof data !== "object" || data === null || Array.isArray(data)) return;
      const set = keySets.get(name) ?? new Set<string>();
      for (const key of Object.keys(data)) set.add(key.slice(0, SHAPE_EVENT_MAX_CHARS));
      keySets.set(name, set);
    },
    fields() {
      return {
        events: Object.fromEntries(counts),
        keys: Object.fromEntries([...keySets].map(([name, set]) => [name, [...set].toSorted()])),
      };
    },
  };
}

/**
 * Delivers a transcript to Hermes: a fresh session named after the memo (or, with a `threadId`, a turn into that existing
 * session), one chat turn over the named-event SSE stream with `systemMessage(mode)` as the turn's system prompt, and the final
 * assistant text as the reply. The ```iris block is cut out of the reply (`parseIrisBlock`) and the names of the tools the
 * turn started (`tool.started` frames) are kept; both come back as `Delivery.meta`. The delivery names the thread (the session id, kind
 * `hermes` and title); `act` only persists it.
 */
export function createHermesDestination(opts: HermesDestinationOptions): Destination {
  const doFetch = opts.fetch ?? fetch;
  const idleMs = opts.idleMs ?? DEFAULT_IDLE_MS;
  const headers = {
    Authorization: `Bearer ${opts.token}`,
    "Content-Type": "application/json",
  };

  return {
    async deliver({ memoId, transcript, mode, threadId }): Promise<Delivery> {
      // A continuation talks into its thread's session, which already exists; a fresh memo gets a session named after it.
      const sessionId = threadId ?? memoId;
      const attrs = { memo_id: memoId, downstream: "hermes" };

      if (threadId === undefined) {
        await withSpan("hermes.create_session", attrs, async (span) => {
          const timeout = AbortSignal.timeout(SESSION_TIMEOUT_MS);
          const res = await doFetch(new URL("/api/sessions", opts.baseUrl).toString(), {
            method: "POST",
            headers,
            body: JSON.stringify({ id: sessionId, source: SOURCE }),
            signal: timeout,
          }).catch((err: unknown) => {
            throw fetchFailure(err);
          });
          span.setAttributes({ status: res.status });
          // 409 session_exists is fine: a retried memo reuses its session.
          if (res.status === 201 || res.status === 409) return;
          throw httpFailure(
            `hermes session create failed: ${res.status} ${await failureMessage(res, timeout)}`,
            res.status,
          );
        });
      }

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
          body: JSON.stringify({ message: transcript, system_message: systemMessage(mode) }),
          signal: controller.signal,
        }).catch((err: unknown) => {
          clearTimeout(timer);
          if (controller.signal.aborted) {
            throw hangGuardFailure(`hermes did not respond within ${idleMs} ms`);
          }
          throw fetchFailure(err);
        });
        span.setAttributes({ status: res.status });
        if (res.status !== 200 || !res.body) {
          // The abort guard stays armed through the error-body read, so a stalled body cannot hang the turn.
          const message = await failureMessage(res, controller.signal).finally(() =>
            clearTimeout(timer),
          );
          throw httpFailure(`hermes chat failed: ${res.status} ${message}`, res.status);
        }
        clearTimeout(timer);

        let reply: { content: string; interrupted: boolean } | null = null;
        let usage: { inputTokens: number; outputTokens: number; totalTokens: number } | undefined;
        let sawDone = false;
        const toolNames: string[] = [];
        const shape = frameShape();

        try {
          for await (const frame of readSseFrames(res.body, { idleMs })) {
            shape.add(frame);
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
            } else if (frame.event === "tool.started") {
              const started = ToolStarted.safeParse(parseData(frame));
              const action = started.success ? actionOf(started.data) : null;
              if (action !== null) toolNames.push(action);
            } else if (frame.event === "error") {
              const failed = ErrorEvent.safeParse(parseData(frame));
              throw new Error(`hermes error: ${failed.success ? failed.data.message : frame.data}`);
            } else if (frame.event === "done") {
              sawDone = true;
              break;
            }
          }
        } catch (err) {
          if (err instanceof SseIdleError) {
            throw hangGuardFailure(`hermes stream idle for ${idleMs} ms`, { cause: err });
          }
          throw err;
        }

        if (!sawDone) throw new Error("hermes stream ended without done");
        if (reply?.interrupted) throw new Error("hermes reply was interrupted");

        const parsed = parseIrisBlock(reply?.content ?? "");
        if (parsed.invalid !== undefined) {
          log("hermes.meta_invalid", { memo_id: memoId, reason: parsed.invalid });
        }
        const actions = normalizeActions(toolNames);
        const meta: DeliveryMeta = {
          kind: parsed.meta?.kind ?? null,
          headline: parsed.meta?.headline ?? null,
          actions,
        };
        log("hermes.frames", { memo_id: memoId, ...shape.fields() });
        log("hermes.delivered", {
          memo_id: memoId,
          reply_chars: parsed.reply.length,
          kind: meta.kind,
          actions: actions.length,
        });
        return {
          ref: sessionId,
          replyText: parsed.reply,
          thread: { id: sessionId, kind: "hermes", title: threadTitle(transcript) },
          meta,
          ...(usage ? { usage } : {}),
        };
      });
    },
  };
}
