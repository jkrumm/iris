import type { Memo, Summary } from "../memo/memo.js";
import type { ApnsResult, ApnsTransport } from "./apns.js";
import type { AudioCombiner } from "./audio.js";
import type { Decider, Decision } from "./decider.js";
import type { Delivery, Destination } from "./destination.js";
import type { Herd, HerdTab } from "./herd.js";
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

export function fakeDestination(
  options: Options<Delivery> = {},
): Destination & Calls<Parameters<Destination["deliver"]>[0]> {
  const calls: Parameters<Destination["deliver"]>[0][] = [];
  return {
    calls,
    async deliver(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      return { ref: "session-1", replyText: "done", ...options.result };
    },
  };
}

/** Answers `hermes` at 0.9 unless told otherwise; `failWith` makes every call throw. */
export function fakeDecider(
  options: Options<Decision> = {},
): Decider & Calls<Parameters<Decider["decide"]>[0]> {
  const calls: Parameters<Decider["decide"]>[0][] = [];
  return {
    calls,
    async decide(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
      return {
        destination: { choice: "hermes", confidence: 0.9 },
        tab: null,
        model: "fake-decider",
        ...options.result,
      };
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

/** `calls` records `notify`, `phaseCalls` `phase`, `needsRouteCalls` `needsRoute`; `failWith` fails `notify` only. */
export function fakeNotifier(options: { failWith?: Error } = {}): Notifier &
  Calls<{ memo: Memo; summary: Summary }> & {
    phaseCalls: { memo: Memo }[];
    needsRouteCalls: { memo: Memo; reason: string | null }[];
  } {
  const calls: { memo: Memo; summary: Summary }[] = [];
  const phaseCalls: { memo: Memo }[] = [];
  const needsRouteCalls: { memo: Memo; reason: string | null }[] = [];
  return {
    calls,
    phaseCalls,
    needsRouteCalls,
    async needsRoute(params) {
      needsRouteCalls.push(params);
    },
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
export function fakeSpeechCache(): SpeechCache {
  const entries = new Map<string, { text: string; bytes: Uint8Array }>();
  return {
    async get({ memoId, text }) {
      const entry = entries.get(memoId);
      return entry?.text === text ? entry.bytes : null;
    },
    async put({ memoId, text, bytes }) {
      entries.set(memoId, { text, bytes });
    },
  };
}

const DEFAULT_TABS: HerdTab[] = [
  { id: "w1:t1", repo: "iris", label: "server", agentState: "working", lastActivity: null },
  { id: "w2:t1", repo: "dotfiles", label: "1", agentState: "idle", lastActivity: null },
];

export function fakeHerd(
  options: { tabs?: HerdTab[]; failWith?: Error } = {},
): Herd & { calls: number } {
  const herd = {
    calls: 0,
    async snapshot() {
      herd.calls++;
      if (options.failWith) throw options.failWith;
      return options.tabs ?? DEFAULT_TABS;
    },
  };
  return herd;
}
