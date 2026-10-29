import { MemoError } from "../memo/errors.js";
import type { Speaker } from "../ports/speaker.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";

// A hang guard, not a budget: a spoken summary is a few sentences.
const TIMEOUT_MS = 120_000;
const BODY_MAX = 300;
/** The response header naming the agent-workflows run that recorded the call, and its span / log key. */
const RUN_ID_HEADER = "agw-run-id";
const RUN_ID_ATTR = "agw.run_id";

/** A network error, timeout or abort is the door being unavailable, not a bug: a 503, not a 500. */
function unreachable(memoId: string, err: unknown): never {
  const reason = err instanceof Error ? err.message : String(err);
  log("audio_door.speak_failed", { memo_id: memoId, error: reason });
  throw new MemoError("unavailable", `speech synthesis unreachable: ${reason}`);
}

export interface AudioDoorSpeakerOptions {
  /** The door base including the version segment: `http://127.0.0.1:7792/v1`. */
  baseUrl: string;
  /** The `iris` line of the door's caller-token file. */
  token: string;
  fetch?: typeof fetch;
  /** The hang guard; tests shorten it. */
  timeoutMs?: number;
}

/**
 * `POST <audio door>/audio/speech` with `{input, response_format: "mp3"}` and `Authorization: Bearer`.
 * The door owns model and voice choice (an absent `model` resolves to its default route, an absent
 * `voice` to its default) and records spend itself. It answers the audio bytes directly (no JSON
 * envelope); `agw-run-id` names the run that recorded the call and goes on the span and the log lines.
 */
export function createAudioDoorSpeaker(opts: AudioDoorSpeakerOptions): Speaker {
  const doFetch = opts.fetch ?? fetch;
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;
  const url = `${opts.baseUrl.replace(/\/+$/, "")}/audio/speech`;

  return {
    async speak({ memoId, text }) {
      return withSpan(
        "audio_door.speak",
        { memo_id: memoId, downstream: "audio-door", text_chars: text.length },
        async (span) => {
          const res = await doFetch(url, {
            method: "POST",
            headers: {
              "content-type": "application/json",
              authorization: `Bearer ${opts.token}`,
            },
            body: JSON.stringify({ input: text, response_format: "mp3" }),
            signal: AbortSignal.timeout(timeoutMs),
          }).catch((err: unknown) => unreachable(memoId, err));
          const runId = res.headers.get(RUN_ID_HEADER);
          span.setAttributes({ status: res.status, [RUN_ID_ATTR]: runId });
          if (!res.ok) {
            const body = (await res.text().catch(() => "")).slice(0, BODY_MAX);
            log("audio_door.speak_failed", {
              memo_id: memoId,
              status: res.status,
              [RUN_ID_ATTR]: runId,
              body,
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
          return { bytes };
        },
      );
    },
  };
}
