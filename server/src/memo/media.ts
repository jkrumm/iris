import {
  bytesRecording,
  type AudioCombiner,
  type AudioStore,
  type Recording,
} from "../ports/audio.js";
import type { Speaker, SpeechCache } from "../ports/speaker.js";
import { log } from "../telemetry/log.js";
import { MemoError } from "./errors.js";
import type { MemoStore } from "./store.js";

/** What a memo can be played back as: its recording (for the scrubber) and its spoken result. */
export interface MemoMedia {
  /** The concatenated recording, built on first use and then read from disk. */
  recording(id: string): Promise<Recording>;
  /** mp3 of `summary.spoken`, else `replyText`; synthesized once per text and then read from disk. */
  speech(id: string): Promise<Uint8Array>;
}

/** Concurrent callers of one key share a single run, so a burst of requests pays for one concat or one TTS call. */
function createSingleFlight() {
  const running = new Map<string, Promise<unknown>>();
  return <T>(key: string, work: () => Promise<T>): Promise<T> => {
    const existing = running.get(key);
    if (existing) return existing as Promise<T>;
    const run = work().finally(() => running.delete(key));
    running.set(key, run);
    return run;
  };
}

export function createMemoMedia(deps: {
  store: MemoStore;
  audio: AudioStore;
  combiner: AudioCombiner;
  /** Unset when no audio-gateway is configured; `speech` then answers `unavailable`. */
  speaker?: Speaker | undefined;
  speechCache: SpeechCache;
}): MemoMedia {
  const { store, audio, combiner, speaker, speechCache } = deps;
  const once = createSingleFlight();

  const mustGet = (id: string) => {
    const memo = store.getMemo(id);
    if (!memo) throw new MemoError("not_found", `memo ${id} not found`);
    return memo;
  };

  return {
    async recording(id) {
      const memo = mustGet(id);
      if (memo.state === "receiving") {
        throw new MemoError("bad_state", `memo ${id} is still receiving segments`);
      }
      return once(`recording/${id}`, async () => {
        const cached = await audio.readCombined(id);
        if (cached) return cached;
        const segmentPaths = store
          .listSegmentIndices(id)
          .toSorted((a, b) => a - b)
          .map((index) => audio.path({ id, index }));
        const bytes = await combiner.combine(segmentPaths);
        await audio.putCombined({ id, bytes });
        log("memo.recording_combined", { memo_id: id, segments: segmentPaths.length });
        return (await audio.readCombined(id)) ?? bytesRecording(bytes);
      });
    },

    async speech(id) {
      const memo = mustGet(id);
      if (!speaker) throw new MemoError("unavailable", "speech is not configured");
      const text = memo.summary?.spoken.trim() || memo.replyText?.trim();
      if (!text)
        throw new MemoError("bad_state", `memo ${id} has no summary or reply to speak yet`);
      return once(`speech/${id}`, async () => {
        const cached = await speechCache.get({ memoId: id, text });
        if (cached) return cached;
        const { bytes } = await speaker.speak({ memoId: id, text });
        await speechCache.put({ memoId: id, text, bytes });
        return bytes;
      });
    },
  };
}
