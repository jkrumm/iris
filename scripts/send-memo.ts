#!/usr/bin/env bun
/**
 * End-to-end harness: splits an audio file into 10 s m4a segments and drives the /v1 HTTP API
 * exactly like the phone does (create, upload segments, complete, long-poll the result).
 * `--text "<text>"` sends a typed memo instead (POST /v1/memos/text, no audio file).
 *
 *   IRIS_TOKEN=<device-token> bun scripts/send-memo.ts <audio-file> [--url ..] [--mode auto]
 *   IRIS_TOKEN=<device-token> bun scripts/send-memo.ts --text "kauf Milch" [--url ..] [--mode auto]
 *
 * Exit codes: 0 notified, 1 failed, 2 timeout / needs_route / usage error.
 */
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";

const MODES = ["auto", "journal", "hermes", "tab"] as const;
type Mode = (typeof MODES)[number];

const DEFAULT_URL = "http://127.0.0.1:7730";
const DEFAULT_WAIT_SECONDS = 300;
const POLL_SECONDS = 30;
const UPLOAD_CONCURRENCY = 4;
const PREVIEW_CHARS = 200;

/** What to send: a recording to upload, or typed text. */
export type Source = { kind: "file"; path: string } | { kind: "text"; text: string };

export interface Options {
  source: Source;
  url: string;
  token: string;
  mode: Mode;
  waitSeconds: number;
}

const out = (text: string) => process.stdout.write(`${text}\n`);
const err = (text: string) => process.stderr.write(`${text}\n`);

export class UsageError extends Error {}

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown,
    message: string,
  ) {
    super(message);
  }
}

export const USAGE = `usage: IRIS_TOKEN=<token> bun scripts/send-memo.ts <audio-file> | --text "<text>"
  [--url <base>] [--token <token>] [--mode auto|journal|hermes|tab] [--wait <seconds>]
  env: IRIS_URL (default ${DEFAULT_URL}), IRIS_TOKEN (required)`;

function parseSource(params: { text: string | undefined; positionals: string[] }): Source {
  const { text, positionals } = params;
  if (text !== undefined) {
    if (positionals.length > 0) throw new UsageError("--text and an audio file are exclusive");
    if (text.trim() === "") throw new UsageError("--text must not be empty");
    return { kind: "text", text };
  }
  const [path, ...extra] = positionals;
  if (!path || extra.length > 0) throw new UsageError("expected exactly one audio file");
  return { kind: "file", path };
}

export function parseCliArgs(argv: string[], env: Record<string, string | undefined>): Options {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        url: { type: "string" },
        token: { type: "string" },
        mode: { type: "string" },
        wait: { type: "string" },
        text: { type: "string" },
      },
    });
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  const { values, positionals } = parsed;

  const source = parseSource({ text: values.text, positionals });

  const token = values.token ?? env["IRIS_TOKEN"];
  if (!token) throw new UsageError("IRIS_TOKEN (or --token) is required");

  const mode = values.mode ?? "auto";
  if (!MODES.includes(mode as Mode))
    throw new UsageError(`--mode must be one of ${MODES.join("|")}`);

  const waitSeconds = values.wait === undefined ? DEFAULT_WAIT_SECONDS : Number(values.wait);
  if (!Number.isFinite(waitSeconds) || waitSeconds <= 0) {
    throw new UsageError("--wait must be a positive number of seconds");
  }

  const url = (values.url ?? env["IRIS_URL"] ?? DEFAULT_URL).replace(/\/+$/, "");
  return { source, url, token, mode: mode as Mode, waitSeconds };
}

const segmentIndex = (name: string) => Number(/^seg(\d+)\.m4a$/.exec(name)?.[1] ?? Number.NaN);

/** Segment files in `dir` (`segNNNNN.m4a`), sorted by their numeric index. */
export async function listSegments(dir: string): Promise<string[]> {
  const names = (await readdir(dir)).filter((name) => !Number.isNaN(segmentIndex(name)));
  return names.toSorted((a, b) => segmentIndex(a) - segmentIndex(b)).map((name) => join(dir, name));
}

/** Splits `file` into 10 s mono 16 kHz AAC m4a segments inside `dir`. */
export async function splitAudio(params: { file: string; dir: string }): Promise<string[]> {
  const { file, dir } = params;
  const proc = Bun.spawn(
    [
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      file,
      "-vn",
      "-c:a",
      "aac",
      "-b:a",
      "64k",
      "-ar",
      "16000",
      "-ac",
      "1",
      "-f",
      "segment",
      "-segment_time",
      "10",
      "-segment_format",
      "mp4",
      join(dir, "seg%05d.m4a"),
    ],
    { stdout: "ignore", stderr: "pipe" },
  );
  const [stderr, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`ffmpeg exited ${code}: ${stderr.trim()}`);
  const segments = await listSegments(dir);
  if (segments.length === 0) throw new Error("ffmpeg produced no segments");
  return segments;
}

// -- wire shapes (camelCase, see server/src/http/serialize.ts) ---------------------------------

interface StepWire {
  step: string;
  status: string;
  startedAt: string | null;
  finishedAt: string | null;
  error: string | null;
  costUsd: number | null;
}

export interface MemoWire {
  id: string;
  state: string;
  failedStep: string | null;
  error: string | null;
  audioSeconds?: number | null;
  transcript?: string | null;
  replyText?: string | null;
  summary?: { headline?: string; detail?: string } | null;
  steps?: StepWire[];
}

const clip = (text: string | null | undefined) => {
  if (!text) return "-";
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > PREVIEW_CHARS ? `${flat.slice(0, PREVIEW_CHARS)}...` : flat;
};

const stepSeconds = (step: StepWire) => {
  if (!step.startedAt || !step.finishedAt) return null;
  return (Date.parse(step.finishedAt) - Date.parse(step.startedAt)) / 1000;
};

/** The compact human summary printed at the end of a run. */
export function formatSummary(memo: MemoWire): string {
  const steps = memo.steps ?? [];
  const timings = steps
    .map((step) => {
      const seconds = stepSeconds(step);
      return `${step.step}:${step.status}${seconds === null ? "" : ` ${seconds.toFixed(1)}s`}`;
    })
    .join("  ");
  const costs = steps.map((step) => step.costUsd).filter((cost) => cost !== null);
  const cost = costs.length > 0 ? `$${costs.reduce((a, b) => a + b, 0).toFixed(4)}` : "-";
  const lines = [
    `memo        ${memo.id}`,
    `trace       ${memo.id.replaceAll("-", "")}`,
    `state       ${memo.state}`,
    ...(memo.state === "failed"
      ? [`failed      ${memo.failedStep ?? "?"}: ${memo.error ?? "?"}`]
      : []),
    `audio       ${memo.audioSeconds ?? "-"}s`,
    `transcript  ${clip(memo.transcript)}`,
    `reply       ${clip(memo.replyText)}`,
    `summary     ${clip(memo.summary?.headline)}`,
    `detail      ${clip(memo.summary?.detail)}`,
    `steps       ${timings || "-"}`,
    `costUsd     ${cost}`,
  ];
  return lines.join("\n");
}

// -- HTTP --------------------------------------------------------------------------------------

type Json = Record<string, unknown>;

async function request(params: {
  options: Options;
  method: string;
  path: string;
  body?: string | Uint8Array;
  headers?: Record<string, string>;
}): Promise<{ status: number; json: Json | null }> {
  const { options, method, path, body, headers } = params;
  const response = await fetch(`${options.url}/v1${path}`, {
    method,
    headers: { authorization: `Bearer ${options.token}`, ...headers },
    ...(body !== undefined && { body }),
  });
  const json = (await response.json().catch(() => null)) as Json | null;
  if (!response.ok) {
    const detail = typeof json?.["message"] === "string" ? json["message"] : response.statusText;
    throw new ApiError(response.status, json, `${method} ${path} -> ${response.status} ${detail}`);
  }
  return { status: response.status, json };
}

const postJson = (options: Options, path: string, payload: unknown) =>
  request({
    options,
    method: "POST",
    path,
    body: JSON.stringify(payload),
    headers: { "content-type": "application/json" },
  });

/** One retry on a network error or a 5xx; every other error is final. */
async function withRetry<T>(action: () => Promise<T>): Promise<T> {
  try {
    return await action();
  } catch (error) {
    const retryable = !(error instanceof ApiError) || error.status >= 500;
    if (!retryable) throw error;
    return action();
  }
}

async function uploadSegments(params: {
  options: Options;
  id: string;
  files: string[];
  indices: number[];
}): Promise<void> {
  const { options, id, files, indices } = params;
  const queue = [...indices];
  const worker = async () => {
    for (let n = queue.shift(); n !== undefined; n = queue.shift()) {
      const file = files[n];
      if (!file) throw new Error(`no segment file for index ${n}`);
      const bytes = await Bun.file(file).bytes();
      await withRetry(() =>
        request({
          options,
          method: "PUT",
          path: `/memos/${id}/segments/${n}`,
          body: bytes,
          headers: { "content-type": "audio/mp4" },
        }),
      );
    }
  };
  await Promise.all(Array.from({ length: UPLOAD_CONCURRENCY }, worker));
}

async function complete(params: { options: Options; id: string; files: string[] }) {
  const { options, id, files } = params;
  const send = () => postJson(options, `/memos/${id}/complete`, { segmentCount: files.length });
  try {
    await send();
  } catch (error) {
    const missing = error instanceof ApiError && error.status === 422 ? error.body : null;
    const indices = (missing as { missing?: number[] } | null)?.missing;
    if (!indices?.length) throw error;
    out(`re-uploading missing segments: ${indices.join(",")}`);
    await uploadSegments({ options, id, files, indices });
    await send();
  }
}

/** Long-polls until the result is ready (200) or the budget is spent; null on timeout. */
async function awaitResult(options: Options, id: string): Promise<MemoWire | null> {
  const deadline = Date.now() + options.waitSeconds * 1000;
  while (Date.now() < deadline) {
    const remaining = Math.ceil((deadline - Date.now()) / 1000);
    const wait = Math.min(POLL_SECONDS, remaining);
    const { status } = await request({
      options,
      method: "GET",
      path: `/memos/${id}/result?wait=${wait}`,
    });
    if (status === 200) return fetchMemo(options, id);
  }
  return null;
}

async function fetchMemo(options: Options, id: string): Promise<MemoWire> {
  const { json } = await request({ options, method: "GET", path: `/memos/${id}` });
  return json as unknown as MemoWire;
}

/** Creates, uploads and completes a recording; returns the memo id. */
async function submitRecording(options: Options, file: string, dir: string): Promise<string> {
  const files = await splitAudio({ file, dir });
  const id = crypto.randomUUID();
  out(`memo ${id}: ${files.length} segment(s), mode ${options.mode}`);

  await postJson(options, "/memos", {
    id,
    mode: options.mode,
    startedAt: new Date().toISOString(),
  });
  await uploadSegments({ options, id, files, indices: files.map((_, n) => n) });
  await complete({ options, id, files });
  return id;
}

/** Creates a typed memo, which skips ingest and transcribe; returns the memo id. */
async function submitText(options: Options, text: string): Promise<string> {
  const id = crypto.randomUUID();
  out(`memo ${id}: typed, mode ${options.mode}`);
  await postJson(options, "/memos/text", {
    id,
    mode: options.mode,
    startedAt: new Date().toISOString(),
    text,
  });
  return id;
}

/** Runs the whole flow and returns the process exit code. */
export async function sendMemo(options: Options): Promise<number> {
  const dir = await mkdtemp(join(tmpdir(), "iris-send-memo-"));
  try {
    const { source } = options;
    const id =
      source.kind === "text"
        ? await submitText(options, source.text)
        : await submitRecording(options, source.path, dir);

    const ready = await awaitResult(options, id);
    if (!ready) {
      err(`timed out after ${options.waitSeconds}s without a result`);
      err(formatSummary(await fetchMemo(options, id)));
      return 2;
    }
    out(formatSummary(ready));
    if (ready.state === "notified") return 0;
    return ready.state === "failed" ? 1 : 2;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

async function main(): Promise<number> {
  let options: Options;
  try {
    options = parseCliArgs(process.argv.slice(2), process.env);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    err(`${error.message}\n${USAGE}`);
    return 2;
  }
  try {
    return await sendMemo(options);
  } catch (error) {
    err(`error: ${(error as Error).message}`);
    return 2;
  }
}

if (import.meta.main) process.exit(await main());
