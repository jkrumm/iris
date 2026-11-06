import { z } from "zod";
import {
  ASK_KINDS,
  ASK_SOURCES,
  FactoryError,
  HEALTH_KINDS,
  type FactoryAsk,
  type FactoryChange,
  type FactoryHealth,
  type FactoryReader,
} from "../ports/factory.js";
import { readSseFrames } from "./sse.js";

export interface FactoryHttpOptions {
  /** The factory's token API on this machine: `http://127.0.0.1:7793`. */
  baseUrl: string;
  /** `FACTORY_TOKEN`, sent as the bearer on every call. */
  token: string;
  fetch?: typeof fetch;
  /** The hang guard of a read or an answer; tests shorten it. */
  timeoutMs?: number;
  /** A stream with no bytes (keepalives come every 15 s) for this long is dead. */
  streamIdleMs?: number;
}

const DEFAULT_TIMEOUT_MS = 10_000;
const STREAM_IDLE_MS = 45_000;
const CHANGE_EVENTS = ["hello", "issue", "session", "fleet"] as const;

// Not strict: unknown fields are ignored, and an item that does not fit is dropped rather than failing the list.
const AskItem = z.object({
  id: z.string().min(1),
  kind: z.string().optional(),
  source: z.string().optional(),
  short: z.string().nullish(),
  summary: z.string().nullish(),
  text: z.string().nullish(),
  at: z.string(),
  issue: z.number().int().nullish(),
  stale: z.boolean().optional(),
});
const HealthItem = z.object({
  id: z.string().min(1),
  kind: z.string().optional(),
  short: z.string().nullish(),
  summary: z.string().nullish(),
  text: z.string().nullish(),
  since: z.string(),
});
const Overview = z.object({
  builtAt: z.string(),
  asks: z.array(z.unknown()),
  health: z.array(z.unknown()),
});
const AsksBody = z.object({ asks: z.array(z.unknown()) });
const IssueBody = z.object({
  asks: z
    .array(
      z.object({
        options: z.array(z.string()).nullish(),
        answer: z.string().nullish(),
      }),
    )
    .default([]),
});
const AnswerAck = z.object({
  issue: z.number().int(),
  state: z.string(),
  duplicate: z.boolean(),
});

/** An unknown enum value is `other`: the factory adds values within `/v1`. */
const known = <T extends string>(values: readonly T[], value: string | undefined): T =>
  (values as readonly string[]).includes(value ?? "") ? (value as T) : ("other" as T);

function parseAsks(items: unknown[]): FactoryAsk[] {
  return items.flatMap((item) => {
    const parsed = AskItem.safeParse(item);
    if (!parsed.success) return [];
    const { id, at, kind, source, short, summary, text, issue, stale } = parsed.data;
    const body = summary || text || short || "";
    return [
      {
        id,
        kind: known(ASK_KINDS, kind),
        source: known(ASK_SOURCES, source),
        issue: issue ?? null,
        short: short || body,
        summary: body,
        at,
        stale: stale ?? false,
      },
    ];
  });
}

function parseHealth(items: unknown[]): FactoryHealth[] {
  return items.flatMap((item) => {
    const parsed = HealthItem.safeParse(item);
    if (!parsed.success) return [];
    const { id, kind, short, summary, text, since } = parsed.data;
    const body = summary || text || short || "";
    return [{ id, kind: known(HEALTH_KINDS, kind), short: short || body, summary: body, since }];
  });
}

const unavailable = (what: string, cause?: unknown) =>
  new FactoryError("unavailable", `factory ${what} failed`, { cause });

/**
 * The factory's read API over loopback with the bearer token. No redirects (the bearer never follows one elsewhere), a hang
 * guard on every call, and only `FactoryError` escapes: 404 `not_found`, 409 `conflict`, 410 `cursor_gone`, a 400/422
 * `bad_request`, and everything else (401, 5xx, a refused connection, a timeout) `unavailable`. Error bodies are never echoed.
 */
export function createFactoryHttp(opts: FactoryHttpOptions): FactoryReader {
  const doFetch = opts.fetch ?? fetch;
  const base = opts.baseUrl.replace(/\/+$/, "");
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const auth = { authorization: `Bearer ${opts.token}` };

  async function request(what: string, path: string, init: RequestInit): Promise<Response> {
    const res = await doFetch(`${base}${path}`, {
      ...init,
      headers: { ...auth, ...(init.headers as Record<string, string> | undefined) },
      redirect: "error",
    }).catch((err: unknown) => {
      throw unavailable(what, err);
    });
    if (res.ok) return res;
    await res.body?.cancel().catch(() => {});
    switch (res.status) {
      case 404:
        throw new FactoryError("not_found", `factory ${what}: not found`);
      case 409:
        throw new FactoryError("conflict", `factory ${what}: conflict`);
      case 410:
        throw new FactoryError("cursor_gone", `factory ${what}: cursor is gone`);
      case 400:
      case 422:
        throw new FactoryError("bad_request", `factory ${what}: rejected (${res.status})`);
      default:
        throw new FactoryError("unavailable", `factory ${what} failed: ${res.status}`);
    }
  }

  async function json<T extends z.ZodType>(what: string, res: Response, schema: T) {
    const body: unknown = await res.json().catch((err: unknown) => {
      throw unavailable(what, err);
    });
    const parsed = schema.safeParse(body);
    if (!parsed.success) throw unavailable(`${what} (unexpected shape)`);
    return parsed.data as z.infer<T>;
  }

  const get = (what: string, path: string) =>
    request(what, path, { signal: AbortSignal.timeout(timeoutMs) });

  return {
    async overview() {
      const body = await json("overview", await get("overview", "/v1/overview"), Overview);
      return {
        asks: parseAsks(body.asks),
        health: parseHealth(body.health),
        builtAt: body.builtAt,
      };
    },

    async asks() {
      const body = await json("asks", await get("asks", "/v1/asks"), AsksBody);
      return parseAsks(body.asks);
    },

    async issueQuestion(issue) {
      const what = `issue ${issue}`;
      const body = await json(what, await get(what, `/v1/issues/${issue}`), IssueBody);
      // The open question is the newest entry without an answer.
      const open = body.asks.findLast((ask) => ask.answer == null);
      return open?.options ?? [];
    },

    async answer({ issue, callId, text }) {
      const res = await request("answer", `/issues/${issue}/answer`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: callId, answer: text }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      return json("answer", res, AnswerAck);
    },

    async *follow(since, signal) {
      const query = since ? `?since=${encodeURIComponent(since)}` : "";
      const res = await request("stream", `/v1/stream${query}`, {
        headers: { accept: "text/event-stream" },
        signal,
      });
      if (!res.body) throw unavailable("stream");
      for await (const frame of readSseFrames(res.body, {
        idleMs: opts.streamIdleMs ?? STREAM_IDLE_MS,
      })) {
        const event = (CHANGE_EVENTS as readonly string[]).includes(frame.event)
          ? (frame.event as FactoryChange["event"])
          : "other";
        yield { event, cursor: frame.id ?? null };
      }
    },
  };
}
