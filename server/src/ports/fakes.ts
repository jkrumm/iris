import { threadTitle, type Memo, type Summary } from "../memo/memo.js";
import type { ApnsResult, ApnsTransport } from "./apns.js";
import type { AssetStore } from "./assets.js";
import type { AudioCombiner } from "./audio.js";
import type { DiagramRenderer, RenderedDiagram } from "./diagram.js";
import type { Delivery, DeliveryMeta, Destination } from "./destination.js";
import type { Notifier } from "./notifier.js";
import type { Speaker, Speech, SpeechCache } from "./speaker.js";
import type { Summarization, Summarizer } from "./summarizer.js";
import type { Transcriber, TranscriptionResult } from "./transcriber.js";

// Deterministic in-memory ports. Each records its calls; `failWith` makes every call throw it.

type Calls<P> = { calls: P[] };
type Options<R> = { result?: Partial<R>; failWith?: Error };

export function fakeTranscriber(
  options: Options<TranscriptionResult> = {},
): Transcriber & Calls<Parameters<Transcriber["transcribe"]>[0]> {
  const calls: Parameters<Transcriber["transcribe"]>[0][] = [];
  return {
    calls,
    async transcribe(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      return { text: "hello iris", audioSeconds: 12.5, ...options.result };
    },
  };
}

/** What the fake Hermes reports for every turn: a kind, a headline and two tool names, as the `iris` skill's block would. */
export const FAKE_META: DeliveryMeta = {
  kind: "note",
  headline: "Hermes headline",
  actions: ["fake_search", "fake_write"],
};

/**
 * Stands for Hermes: every delivery names its thread (the ref, kind `hermes`) and carries `FAKE_META`. `sessionPerMemo` names the
 * session after the memo like Hermes does; otherwise every memo shares one session (`session-1`). `stream` makes a delivery
 * with an `onProgress` report one tool and then the chunks (the first led by "\n\n" like Hermes's deltas), `gapMs` apart; when
 * `result.replyText` is not set, the reply is the chunks joined.
 */
export function fakeDestination(
  options: Options<Delivery> & {
    sessionPerMemo?: boolean;
    stream?: { chunks: string[]; gapMs: number; tool?: string };
  } = {},
): Destination & Calls<Parameters<Destination["deliver"]>[0]> {
  const calls: Parameters<Destination["deliver"]>[0][] = [];
  return {
    calls,
    async deliver(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      // A continuation lands in its thread's session; otherwise one shared session, or (`sessionPerMemo`) one per memo like Hermes.
      const ref = params.threadId ?? (options.sessionPerMemo ? params.memoId : "session-1");
      const { stream } = options;
      const delivery: Delivery = {
        ref,
        replyText: stream ? stream.chunks.join("") : "done",
        meta: FAKE_META,
        ...options.result,
      };
      if (stream && params.onProgress) {
        params.onProgress({ type: "tool", tool: stream.tool ?? "fake_search" });
        for (const [i, chunk] of stream.chunks.entries()) {
          if (i > 0) await new Promise((resolve) => setTimeout(resolve, stream.gapMs));
          params.onProgress({ type: "text", delta: i === 0 ? `\n\n${chunk}` : chunk });
        }
      }
      if (!delivery.thread) {
        delivery.thread = {
          id: delivery.ref,
          kind: "hermes",
          title: threadTitle(params.transcript),
        };
      }
      return delivery;
    },
  };
}

const DEFAULT_SUMMARY: Summary = { headline: "Headline", detail: "Detail", spoken: "Spoken." };

export function fakeSummarizer(
  options: Options<Summarization> = {},
): Summarizer & Calls<Parameters<Summarizer["summarize"]>[0]> {
  const calls: Parameters<Summarizer["summarize"]>[0][] = [];
  return {
    calls,
    async summarize(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      return { summary: DEFAULT_SUMMARY, ...options.result };
    },
  };
}

/** `calls` records `notify`, `phaseCalls` `phase`; `failWith` fails `notify` only. */
export function fakeNotifier(
  options: { failWith?: Error } = {},
): Notifier & Calls<{ memo: Memo; summary: Summary }> & { phaseCalls: { memo: Memo }[] } {
  const calls: { memo: Memo; summary: Summary }[] = [];
  const phaseCalls: { memo: Memo }[] = [];
  return {
    calls,
    phaseCalls,
    async notify(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
    },
    async phase(params) {
      phaseCalls.push(params);
    },
  };
}

/** Records every send; `results` are consumed in order, then sends succeed. */
export function fakeApnsTransport(
  options: { results?: ApnsResult[] } = {},
): ApnsTransport & Calls<Parameters<ApnsTransport["send"]>[0]> {
  const calls: Parameters<ApnsTransport["send"]>[0][] = [];
  const results = [...(options.results ?? [])];
  return {
    calls,
    async send(params) {
      calls.push(params);
      return results.shift() ?? { ok: true };
    },
  };
}

export function fakeCombiner(
  options: { bytes?: Uint8Array; failWith?: Error } = {},
): AudioCombiner & Calls<string[]> {
  const calls: string[][] = [];
  return {
    calls,
    async combine(segmentPaths) {
      calls.push(segmentPaths);
      if (options.failWith) throw options.failWith;
      return options.bytes ?? new Uint8Array(Array.from({ length: 100 }, (_, i) => i));
    },
  };
}

export function fakeSpeaker(
  options: Options<Speech> = {},
): Speaker & Calls<Parameters<Speaker["speak"]>[0]> {
  const calls: Parameters<Speaker["speak"]>[0][] = [];
  return {
    calls,
    async speak(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      return { bytes: new TextEncoder().encode(`mp3:${params.text}`), ...options.result };
    },
  };
}

/** In-memory cache keyed by memo id; one entry per memo, replaced when the text changes. */
export function fakeSpeechCache(): SpeechCache & { entries: Map<string, unknown> } {
  const entries = new Map<string, { text: string; bytes: Uint8Array }>();
  return {
    entries,
    async get({ memoId, text }) {
      const entry = entries.get(memoId);
      return entry?.text === text ? entry.bytes : null;
    },
    async put({ memoId, text, bytes }) {
      entries.set(memoId, { text, bytes });
    },
    async remove(memoId) {
      entries.delete(memoId);
    },
  };
}

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const encoder = new TextEncoder();

/**
 * Renders every source to a tiny SVG naming the scheme and source, plus a PNG-signed body; a source that contains
 * `failOn` (default: any source with the word "unrenderable") throws like a diagram the real renderer rejects.
 */
export function fakeDiagramRenderer(
  options: { failOn?: string; result?: Partial<RenderedDiagram> } = {},
): DiagramRenderer & Calls<string> {
  const calls: string[] = [];
  const failOn = options.failOn ?? "unrenderable";
  return {
    calls,
    async render(source) {
      calls.push(source);
      if (source.includes(failOn)) throw new Error("fake diagram renderer: cannot render");
      const scheme = (name: "light" | "dark") => ({
        svg: `<svg xmlns="http://www.w3.org/2000/svg" data-scheme="${name}"><desc>${source.length}</desc></svg>`,
        png: new Uint8Array([...PNG_SIGNATURE, ...encoder.encode(`${name}:${source}`)]),
      });
      return {
        width: 120,
        height: 60,
        light: scheme("light"),
        dark: scheme("dark"),
        ...options.result,
      };
    },
  };
}

/** In-memory asset files keyed `<memo id>/<asset id>`. */
export function fakeAssetStore(): AssetStore & { files: Map<string, Uint8Array> } {
  const files = new Map<string, Uint8Array>();
  // A memo's directory changes when a file is added or deleted (the file system's mtime); a counter stands in for the clock.
  const changed = new Map<string, number>();
  let tick = 0;
  const touch = (memoId: string) => changed.set(memoId, ++tick);
  return {
    files,
    async put({ memoId, assetId, bytes }) {
      files.set(`${memoId}/${assetId}`, bytes);
      touch(memoId);
    },
    async read({ memoId, assetId }) {
      return files.get(`${memoId}/${assetId}`) ?? null;
    },
    async remove({ memoId, assetIds }) {
      for (const assetId of assetIds) if (files.delete(`${memoId}/${assetId}`)) touch(memoId);
    },
    async listMemos() {
      const memos = new Set([...files.keys()].map((key) => key.split("/")[0] as string));
      return [...memos].sort((a, b) => (changed.get(b) ?? 0) - (changed.get(a) ?? 0));
    },
    async list(memoId) {
      return [...files.keys()]
        .filter((key) => key.startsWith(`${memoId}/`))
        .map((key) => key.slice(memoId.length + 1));
    },
    async prune({ memoId, keep }) {
      for (const key of files.keys()) {
        if (key.startsWith(`${memoId}/`) && !keep.has(key.slice(memoId.length + 1))) {
          files.delete(key);
          touch(memoId);
        }
      }
    },
    async removeAll(memoId) {
      for (const key of files.keys()) if (key.startsWith(`${memoId}/`)) files.delete(key);
      changed.delete(memoId);
    },
  };
}
