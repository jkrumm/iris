import { MemoError } from "../memo/errors.js";
import type { Speaker } from "../ports/speaker.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";

// A hang guard, not a budget: a spoken summary is a few sentences.
const TIMEOUT_MS = 120_000;
const BODY_MAX = 300;

/** A network error, timeout or abort is the gateway being unavailable, not a bug: a 503, not a 500. */
function unreachable(memoId: string, err: unknown): never {
  const reason = err instanceof Error ? err.message : String(err);
  log("audio_gateway.speak_failed", { memo_id: memoId, error: reason });
  throw new MemoError("unavailable", `speech synthesis unreachable: ${reason}`);
}

export interface AudioGatewaySpeakerOptions {
  baseUrl: string;
  fetch?: typeof fetch;
  /** The hang guard; tests shorten it. */
  timeoutMs?: number;
}

/**
 * `POST <audio-gateway>/v1/audio/speech` with `{input, response_format: "mp3"}` and
 * `x-audio-source: iris` (audio-gateway README, verified against `src/speech.ts`). The gateway owns
 * model and voice choice: an absent `model` resolves to its configured TTS model, an absent `voice`
 * to its default, and the language is detected from the text. It answers the audio bytes
 * directly (no JSON envelope) and records spend itself.
 */
export function createAudioGatewaySpeaker(opts: AudioGatewaySpeakerOptions): Speaker {
  const doFetch = opts.fetch ?? fetch;
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;
  const url = `${opts.baseUrl.replace(/\/+$/, "")}/v1/audio/speech`;

  return {
    async speak({ memoId, text }) {
      return withSpan(
        "audio_gateway.speak",
        { memo_id: memoId, downstream: "audio-gateway", text_chars: text.length },
        async (span) => {
          const res = await doFetch(url, {
            method: "POST",
            headers: { "content-type": "application/json", "x-audio-source": "iris" },
            body: JSON.stringify({ input: text, response_format: "mp3" }),
            signal: AbortSignal.timeout(timeoutMs),
          }).catch((err: unknown) => unreachable(memoId, err));
          span.setAttributes({ status: res.status });
          if (!res.ok) {
            const body = (await res.text().catch(() => "")).slice(0, BODY_MAX);
            log("audio_gateway.speak_failed", { memo_id: memoId, status: res.status, body });
            throw new MemoError("unavailable", `speech synthesis failed: ${res.status}`);
          }
          const bytes = new Uint8Array(
            await res.arrayBuffer().catch((err: unknown) => unreachable(memoId, err)),
          );
          if (bytes.byteLength === 0) {
            throw new MemoError("unavailable", "speech synthesis returned no audio");
          }
          log("audio_gateway.spoke", { memo_id: memoId, bytes: bytes.byteLength });
          return { bytes };
        },
      );
    },
  };
}
