import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import type { AudioCombiner } from "../ports/audio.js";
import { fetchFailure, hangGuardFailure, httpFailure } from "../ports/transient.js";
import type { Transcriber, TranscriptionResult } from "../ports/transcriber.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";

const MODEL = "voxtral-mini-transcribe-3-0";
// A hang guard, not a budget: long recordings are chunked and transcribed server-side.
const TIMEOUT_MS = 1_800_000;
const BODY_MAX = 300;
const STDERR_TAIL = 500;

export type ConcatFn = (paths: string[]) => Promise<{ bytes: Uint8Array; seconds: number }>;

export interface AudioGatewayTranscriberOptions {
  baseUrl: string;
  fetch?: typeof fetch;
  concat?: ConcatFn;
  /** The hang guard; tests shorten it. */
  timeoutMs?: number;
}

const TranscriptionResponse = z.object({ text: z.string() });

async function run(cmd: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { code, stdout, stderr };
}

function failure(tool: string, stderr: string, code: number): Error {
  return new Error(`${tool} exited with ${code}: ${stderr.trim().slice(-STDERR_TAIL)}`);
}

/** Single quotes are the only character the concat demuxer's quoted paths need escaped. */
const concatLine = (path: string) => `file '${path.replaceAll("'", "'\\''")}'`;

/**
 * Joins the segments with ffmpeg's concat demuxer and re-encodes them as mono 16 kHz AAC in
 * m4a, the shape the transcription model wants. Works in a fresh temp dir that is always removed.
 */
export const ffmpegConcat: ConcatFn = async (paths) => {
  if (paths.length === 0) throw new Error("concat: no segments given");
  for (const path of paths) {
    if (!(await Bun.file(path).exists())) throw new Error(`concat: segment file missing: ${path}`);
  }

  const dir = await mkdtemp(join(tmpdir(), "iris-concat-"));
  try {
    const list = join(dir, "list.txt");
    const out = join(dir, "memo.m4a");
    await writeFile(list, `${paths.map(concatLine).join("\n")}\n`);

    const ffmpeg = await run([
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-f",
      "concat",
      "-safe",
      "0",
      "-i",
      list,
      "-vn",
      "-ac",
      "1",
      "-ar",
      "16000",
      "-c:a",
      "aac",
      "-b:a",
      "32k",
      "-movflags",
      "+faststart",
      out,
    ]);
    if (ffmpeg.code !== 0) throw failure("ffmpeg", ffmpeg.stderr, ffmpeg.code);

    const probe = await run([
      "ffprobe",
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "csv=p=0",
      out,
    ]);
    if (probe.code !== 0) throw failure("ffprobe", probe.stderr, probe.code);
    const seconds = Number.parseFloat(probe.stdout.trim());
    if (!Number.isFinite(seconds)) {
      throw new Error(`ffprobe returned no duration: ${probe.stdout.trim().slice(0, 100)}`);
    }

    return { bytes: new Uint8Array(await Bun.file(out).arrayBuffer()), seconds };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
};

/** The scrubber serves the same mono 16 kHz m4a the transcriber receives. */
export const ffmpegCombiner: AudioCombiner = {
  async combine(paths) {
    return (await ffmpegConcat(paths)).bytes;
  },
};

export function createAudioGatewayTranscriber(opts: AudioGatewayTranscriberOptions): Transcriber {
  const doFetch = opts.fetch ?? fetch;
  const concat = opts.concat ?? ffmpegConcat;
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;
  const url = `${opts.baseUrl.replace(/\/+$/, "")}/v1/audio/transcriptions`;

  return {
    async transcribe({ memoId, segmentPaths, language }): Promise<TranscriptionResult> {
      const { bytes, seconds } = await concat(segmentPaths);

      const form = new FormData();
      form.append("file", new Blob([bytes], { type: "audio/mp4" }), "memo.m4a");
      form.append("model", MODEL);
      form.append("response_format", "json");
      if (language) form.append("language", language);

      return withSpan(
        "audio_gateway.transcribe",
        { memo_id: memoId, downstream: "audio-gateway" },
        async (span) => {
          const res = await doFetch(url, {
            method: "POST",
            headers: { "x-audio-source": "iris" },
            body: form,
            signal: AbortSignal.timeout(timeoutMs),
          }).catch((err: unknown) => {
            // The hang guard fired: the step fails after this one window, it is not retried (`hangGuardFailure`).
            if (err instanceof Error && err.name === "TimeoutError") {
              throw hangGuardFailure(
                `audio-gateway transcription timed out after ${timeoutMs} ms`,
                {
                  cause: err,
                },
              );
            }
            throw fetchFailure(err);
          });
          span.setAttributes({ status: res.status });
          if (!res.ok) {
            const body = (await res.text().catch(() => "")).slice(0, BODY_MAX);
            const kind = res.status === 413 ? " (413 is terminal: the audio is too large)" : "";
            throw httpFailure(
              `audio-gateway transcription failed: ${res.status}${kind} ${body}`,
              res.status,
            );
          }

          const parsed = TranscriptionResponse.safeParse(await res.json().catch(() => null));
          if (!parsed.success) {
            throw new Error("audio-gateway transcription response has no text field");
          }
          log("audio_gateway.transcribed", {
            memo_id: memoId,
            audio_seconds: seconds,
            text_chars: parsed.data.text.length,
          });
          return { text: parsed.data.text, audioSeconds: seconds };
        },
      );
    },
  };
}
