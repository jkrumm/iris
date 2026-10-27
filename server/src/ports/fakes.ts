import type { Memo, Summary } from "../memo/memo.js";
import type { Delivery, Destination } from "./destination.js";
import type { Notifier } from "./notifier.js";
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

export function fakeNotifier(
  options: { failWith?: Error } = {},
): Notifier & Calls<{ memo: Memo; summary: Summary }> {
  const calls: { memo: Memo; summary: Summary }[] = [];
  return {
    calls,
    async notify(params) {
      calls.push(params);
      if (options.failWith) throw options.failWith;
    },
  };
}
