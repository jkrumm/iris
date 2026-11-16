import { MemoError } from "../memo/errors.js";
import { SPEECH_CHUNK_CHARS, splitForSpeech } from "../memo/speech-text.js";
import type { Speaker } from "../ports/speaker.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";
import { RUN_ID_ATTR, type AudioDoorClient } from "./audio-door-client.js";

// A hang guard, not a budget: it covers one call, and a call carries at most `SPEECH_CHUNK_CHARS`.
const TIMEOUT_MS = 120_000;
const BODY_MAX = 300;

/** A network error, timeout or abort is the door being unavailable, not a bug: a 503, not a 500. */
function unreachable(memoId: string, err: unknown): never {
  const reason = err instanceof Error ? err.message : String(err);
  log("audio_door.speak_failed", { memo_id: memoId, error: reason });
  throw new MemoError("unavailable", `speech synthesis unreachable: ${reason}`);
}

export interface AudioDoorSpeakerOptions {
  client: AudioDoorClient;
  /** The hang guard; tests shorten it. */
  timeoutMs?: number;
}

/**
 * `POST <audio door>/audio/speech` with `{input, response_format: "mp3"}` and `Authorization: Bearer`.
 * The door owns model and voice choice (an absent `model` resolves to its default route, an absent
 * `voice` to its default) and records spend itself. It answers the audio bytes directly (no JSON
 * envelope); `agw-run-id` names the run that recorded the call and goes on the span and the log lines.
 * The door answers 400 over 4096 characters, so a longer text goes in pieces (`splitForSpeech`), one call after the
 * other, and the mp3 files are joined: mp3 is a frame stream, so the concatenation plays as one.
 */
export function createAudioDoorSpeaker(opts: AudioDoorSpeakerOptions): Speaker {
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;

  /** One door call for a text under the door's input limit. */
  const speakOne = (memoId: string, text: string): Promise<Uint8Array> =>
    withSpan(
      "audio_door.speak",
      { memo_id: memoId, downstream: "audio-door", text_chars: text.length },
      async (span) => {
        const { res, runId } = await opts.client
          .post({
            path: "/audio/speech",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ input: text, response_format: "mp3" }),
            timeoutMs,
          })
          .catch((err: unknown) => unreachable(memoId, err));
        span.setAttributes({ status: res.status, [RUN_ID_ATTR]: runId });
        if (!res.ok) {
          const body = (await res.text().catch(() => "")).slice(0, BODY_MAX);
          log("audio_door.speak_failed", {
            memo_id: memoId,
            status: res.status,
            [RUN_ID_ATTR]: runId,
            body_chars: body.length,
          });
          throw new MemoError("unavailable", `speech synthesis failed: ${res.status}`);
        }
        const bytes = new Uint8Array(
          await res.arrayBuffer().catch((err: unknown) => unreachable(memoId, err)),
        );
        if (bytes.byteLength === 0) {
          throw new MemoError("unavailable", "speech synthesis returned no audio");
        }
        log("audio_door.spoke", {
          memo_id: memoId,
          [RUN_ID_ATTR]: runId,
          bytes: bytes.byteLength,
        });
        return bytes;
      },
    );

  return {
    async speak({ memoId, text }) {
      const pieces = text.length <= SPEECH_CHUNK_CHARS ? [text] : splitForSpeech(text);
      const parts: Uint8Array[] = [];
      for (const piece of pieces) parts.push(await speakOne(memoId, piece));
      if (parts.length === 1) return { bytes: parts[0] as Uint8Array };
      const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.byteLength, 0));
      let offset = 0;
      for (const part of parts) {
        bytes.set(part, offset);
        offset += part.byteLength;
      }
      return { bytes };
    },
  };
}
