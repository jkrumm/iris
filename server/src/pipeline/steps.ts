import { createKeyedQueue } from "../memo/keyed-queue.js";
import {
  clipCodePoints,
  continuedThread,
  DETAIL_MAX,
  HEADLINE_MAX,
  type HandlerStep,
  type Memo,
  type Summary,
} from "../memo/memo.js";
import type { StepHandler } from "../memo/runner.js";
import type { ReplyAssets } from "../memo/reply-assets.js";
import type { AudioStore } from "../ports/audio.js";
import type { Destination } from "../ports/destination.js";
import type { Notifier } from "../ports/notifier.js";
import type { Summarizer } from "../ports/summarizer.js";
import type { Transcriber } from "../ports/transcriber.js";
import type { MemoStore } from "../memo/store.js";
import { getActiveSpan } from "../telemetry/otel.js";

// Each step is a pure function of (memo, ports): it reads what earlier steps stored on the memo,
// returns its own result as a patch and never writes the store itself, so it is safe to re-run.

// How long a turn waits for the turn ahead of it in the same Hermes thread: the size of a hang guard, since a turn has
// an idle watchdog but no wall-clock cap.
const THREAD_WAIT_MS = 1_800_000;

/** What notify announces when neither triage nor Hermes gave a headline: the transcript clipped to one, nothing is stored. */
function transcriptSummary(transcript: string): Summary {
  const text = transcript.replace(/\s+/g, " ").trim();
  return {
    headline: clipCodePoints(text, HEADLINE_MAX),
    detail: clipCodePoints(text, DETAIL_MAX),
    spoken: "",
  };
}

function required<T>(value: T | null, what: string, step: HandlerStep): T {
  if (value === null) throw new Error(`${step}: memo has no ${what}`);
  return value;
}

export function createStepHandlers(deps: {
  store: MemoStore;
  audio: AudioStore;
  transcriber?: Transcriber | undefined;
  /** Hermes, where every memo but a `transcribe` one goes; absent, `act` has no handler and memos wait at `transcribed`. */
  destination?: Destination | undefined;
  /** agw `triage`, behind `summarize`; absent, the step fails and is skipped (it is optional). */
  summarizer?: Summarizer | undefined;
  /** Renders the reply's Mermaid blocks once it is delivered; absent, a reply stays plain markdown. */
  replyAssets?: ReplyAssets | undefined;
  notifier: Notifier;
}): Partial<Record<HandlerStep, StepHandler>> {
  const { store, audio, transcriber, destination, summarizer, replyAssets, notifier } = deps;

  // Turns into one Hermes session run one at a time (a session's key is its thread id, else the opening memo's id): a second memo for the same thread waits for the first's reply, up
  // to `THREAD_WAIT_MS`; past that it fails and names the turn ahead (`POST /retry` re-queues it). The wait gives up the
  // runner's `driveAll` slot (`whileWaiting`), so a parked waiter never keeps an unrelated memo from starting.
  const inThread = createKeyedQueue({ maxWaitMs: THREAD_WAIT_MS });
  const handlers: Partial<Record<HandlerStep, StepHandler>> = {};

  if (transcriber) {
    handlers.transcribe = async ({ memo }) => {
      const segmentPaths = store
        .listSegmentIndices(memo.id)
        .filter((index) => memo.segmentCount === null || index < memo.segmentCount)
        .toSorted((a, b) => a - b)
        .map((index) => audio.path({ id: memo.id, index }));
      const result = await transcriber.transcribe({ memoId: memo.id, segmentPaths });
      if (result.text.trim() === "") throw new Error("empty transcript");
      getActiveSpan().setAttributes({
        audio_seconds: result.audioSeconds,
        transcript_chars: result.text.length,
        cost_usd: result.costUsd,
      });
      return {
        patch: { transcript: result.text, audioSeconds: result.audioSeconds },
        usage: { audioSeconds: result.audioSeconds },
        ...(result.costUsd !== undefined && { costUsd: result.costUsd }),
      };
    };
  }

  // Without Hermes there is nothing to hand the memo to: it waits at `transcribed` until one is configured.
  if (destination) {
    handlers.act = async ({ memo, whileWaiting }) => {
      const transcript = required(memo.transcript, "transcript", "act");
      // A reply into a thread goes to the Hermes session that holds it.
      const threadId = continuedThread(memo);
      const deliver = () =>
        destination.deliver({
          memoId: memo.id,
          transcript,
          mode: memo.mode,
          ...(threadId && { threadId }),
        });
      // A memo that opens its session queues under its own id, the id its session is named after: a retry of it from `act`
      // must not run beside a continuation delivering into that session.
      const delivery = await inThread(threadId ?? memo.id, deliver, {
        label: `memo ${memo.id}`,
        whileWaiting,
      });
      getActiveSpan().setAttributes({
        reply_chars: delivery.replyText.length,
        kind: delivery.meta?.kind ?? "",
        actions: delivery.meta?.actions.length ?? 0,
        cost_usd: delivery.costUsd,
      });
      await replyAssets?.sync({ memoId: memo.id, replyText: delivery.replyText });
      return {
        patch: {
          destinationRef: delivery.ref,
          replyText: delivery.replyText,
          ...(delivery.thread && { thread: delivery.thread }),
          // Always written, so a re-run of `act` replaces what the first run left.
          kind: delivery.meta?.kind ?? null,
          hermesHeadline: delivery.meta?.headline ?? null,
          actions: delivery.meta?.actions ?? [],
        },
        usage: delivery.usage,
        ...(delivery.costUsd !== undefined && { costUsd: delivery.costUsd }),
      };
    };
  }

  // Always present: without a summarizer (or when triage fails) the step fails and the runner skips it, `summarize` being optional.
  // Triage sees the transcript and the final reply only, never tool traffic; every memo it summarizes went to Hermes.
  handlers.summarize = async ({ memo }) => {
    if (!summarizer) throw new Error("summarize: no summarizer configured");
    const result = await summarizer.summarize({
      memoId: memo.id,
      route: "hermes",
      transcript: required(memo.transcript, "transcript", "summarize"),
      replyText: memo.replyText,
    });
    getActiveSpan().setAttributes({
      summary_chars: result.summary.headline.length + result.summary.detail.length,
      cost_usd: result.costUsd,
    });
    return {
      patch: { summary: result.summary },
      usage: result.usage,
      ...(result.costUsd !== undefined && { costUsd: result.costUsd }),
    };
  };

  handlers.notify = async ({ memo }: { memo: Memo }) => {
    // The headline: triage's, else the one Hermes put in its block, else the start of what was said (nothing is stored).
    const summary: Summary =
      memo.summary ??
      (memo.hermesHeadline !== null
        ? { headline: memo.hermesHeadline, detail: "", spoken: "" }
        : transcriptSummary(required(memo.transcript, "transcript", "notify")));
    await notifier.notify({ memo, summary });
    return {};
  };

  return handlers;
}
