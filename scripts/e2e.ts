#!/usr/bin/env bun
/**
 * Pipeline end to end against a server booted with IRIS_FAKES=1: send-memo drives a real recording
 * to `notified`, then the R1 endpoints are probed. Always kills the server; on failure prints its output.
 *
 *   make e2e
 */
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const ROOT = dirname(import.meta.dir);
const HEALTH_DEADLINE_MS = 20_000;
const TAIL_LINES = 60;

const TOKEN = `e2e-${crypto.randomUUID()}`;
const output: string[] = [];
let server: Bun.Subprocess | undefined;
let dataDir: string | undefined;

const out = (line: string) => process.stdout.write(`${line}\n`);
const err = (line: string) => process.stderr.write(`${line}\n`);

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function freePort(): number {
  const listener = Bun.serve({ port: 0, fetch: () => new Response() });
  const port = listener.port;
  void listener.stop(true);
  if (port === undefined) throw new Error("no free port");
  return port;
}

async function capture(stream: ReadableStream<Uint8Array>) {
  for await (const chunk of stream) output.push(new TextDecoder().decode(chunk));
}

async function waitHealthy(base: string) {
  const deadline = Date.now() + HEALTH_DEADLINE_MS;
  while (Date.now() < deadline) {
    if (server?.exitCode !== null) throw new Error(`server exited ${server?.exitCode} during boot`);
    const res = await fetch(`${base}/health`).catch(() => null);
    if (res?.ok) {
      const body = (await res.json()) as { status: string; degraded: string[] };
      assert(body.degraded.includes("fakes"), `/health lists "fakes" (got ${body.degraded})`);
      return;
    }
    await Bun.sleep(200);
  }
  throw new Error(`server not healthy within ${HEALTH_DEADLINE_MS / 1000}s`);
}

async function probe(base: string) {
  const call = (path: string, init: RequestInit = {}) =>
    fetch(`${base}/v1${path}`, {
      ...init,
      headers: { authorization: `Bearer ${TOKEN}`, ...init.headers },
    });
  const json = { "content-type": "application/json" };

  const list = (await (await call("/memos?limit=1")).json()) as { items: { id: string }[] };
  const id = list.items[0]?.id;
  assert(id, "GET /memos?limit=1 returns the memo send-memo created");

  // The fake Hermes reports a kind, a headline and two tool names, like the `iris` skill's block and the stream would.
  const memo = (await (await call(`/memos/${id}`)).json()) as HermesMemo;
  assert(memo.state === "notified", `the memo is notified (got ${memo.state})`);
  assertHermesResult(memo);
  const steps = memo.steps.map((step) => step.step).join(",");
  assert(steps === "transcribe,act,notify", `pipeline is transcribe, act, notify (got ${steps})`);

  const register = await call("/devices/register", {
    method: "POST",
    headers: json,
    body: JSON.stringify({ name: "e2e phone", platform: "ios" }),
  });
  assert(register.status === 200, `POST /devices/register 200 (got ${register.status})`);

  const activity = await call(`/memos/${id}/activity-token`, {
    method: "PUT",
    headers: json,
    body: JSON.stringify({ token: "abcdef0123456789" }),
  });
  assert(activity.status === 204, `PUT activity-token 204 (got ${activity.status})`);

  const audio = await call(`/memos/${id}/audio`, { headers: { range: "bytes=0-99" } });
  const range = audio.headers.get("content-range");
  assert(audio.status === 206, `GET /audio with Range 206 (got ${audio.status})`);
  assert(range?.startsWith("bytes 0-99/"), `Content-Range for bytes 0-99 (got ${range})`);
  assert((await audio.arrayBuffer()).byteLength === 100, "GET /audio returns 100 bytes");

  const speech = await call(`/memos/${id}/speech`);
  const type = speech.headers.get("content-type");
  assert(speech.status === 200, `GET /speech 200 (got ${speech.status})`);
  assert(type?.startsWith("audio/mpeg"), `/speech is audio/mpeg (got ${type})`);
  assert((await speech.arrayBuffer()).byteLength > 0, "/speech has bytes");

  out(`e2e: R1 endpoints ok for memo ${id}`);
}

/** A typed memo skips transcribe: it reaches notified with no ingest or transcribe rows. */
async function probeTyped(base: string) {
  const send = Bun.spawn(
    [
      "bun",
      "scripts/send-memo.ts",
      "--text",
      "Erinnere mich morgen an den Zahnarzt.",
      "--url",
      base,
      "--token",
      TOKEN,
      "--mode",
      "hermes",
    ],
    { cwd: ROOT, stdout: "ignore", stderr: "ignore" },
  );
  assert((await send.exited) === 0, "send-memo --text reached notified (exit 0)");

  const call = (path: string) =>
    fetch(`${base}/v1${path}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const list = (await (await call("/memos?limit=1")).json()) as { items: { id: string }[] };
  const id = list.items[0]?.id;
  assert(id, "GET /memos?limit=1 returns the typed memo");
  const detail = (await (await call(`/memos/${id}`)).json()) as {
    state: string;
    transcript: string | null;
    segmentCount: number;
    typed?: boolean;
    steps: { step: string }[];
  };
  assert(detail.state === "notified", `typed memo is notified (got ${detail.state})`);
  assert(detail.transcript?.startsWith("Erinnere"), "typed memo keeps its text as transcript");
  assert(detail.typed === true, `typed memo carries typed: true (got ${detail.typed})`);
  assert(detail.segmentCount === 0, `typed memo has no segments (got ${detail.segmentCount})`);
  const steps = detail.steps.map((step) => step.step).join(",");
  assert(steps === "act,notify", `no ingest/transcribe rows (got ${steps})`);
  out(`e2e: typed memo ok for memo ${id}`);
}

interface TypedMemo {
  id: string;
  mode: string;
  state: string;
  route: string | null;
  threadId?: string;
  kind?: string;
  actions?: string[];
  summary: { headline: string; detail: string; spoken: string } | null;
  steps: { step: string }[];
}

type HermesMemo = TypedMemo;

/** A memo that went through the fake Hermes: kind, headline and the two tool names are on it, and it was not routed. */
function assertHermesResult(memo: HermesMemo) {
  assert(memo.kind === "note", `the memo carries Hermes's kind (got ${memo.kind})`);
  assert(
    memo.summary?.headline === "Headline",
    `the summary is Hermes's headline (got ${memo.summary?.headline})`,
  );
  assert(
    memo.actions?.join() === "fake_search,fake_write",
    `the memo lists the tools Hermes used (got ${memo.actions?.join()})`,
  );
  assert(memo.route === null, `a new memo has no route (got ${memo.route})`);
}

/** Sends `text` as a typed memo in `mode`, requires `notified`, and returns the memo it created. */
async function sendTyped(
  base: string,
  text: string,
  mode: string,
  threadId?: string,
): Promise<TypedMemo> {
  const send = Bun.spawn(
    [
      "bun",
      "scripts/send-memo.ts",
      "--text",
      text,
      "--url",
      base,
      "--token",
      TOKEN,
      "--mode",
      mode,
      ...(threadId ? ["--thread", threadId] : []),
    ],
    { cwd: ROOT, stdout: "ignore", stderr: "ignore" },
  );
  assert((await send.exited) === 0, `send-memo --text --mode ${mode} reached notified (exit 0)`);

  const call = (path: string) =>
    fetch(`${base}/v1${path}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const list = (await (await call("/memos?limit=1")).json()) as { items: { id: string }[] };
  const id = list.items[0]?.id;
  assert(id, `GET /memos?limit=1 returns the ${mode} memo`);
  return (await (await call(`/memos/${id}`)).json()) as TypedMemo;
}

/** Mode transcribe: a recording ends notified after transcribe and notify alone, with the transcript and no route, reply or summary. */
async function probeTranscribe(base: string) {
  const send = Bun.spawn(
    [
      "bun",
      "scripts/send-memo.ts",
      "fixtures/audio/de-90s.m4a",
      "--url",
      base,
      "--token",
      TOKEN,
      "--mode",
      "transcribe",
    ],
    { cwd: ROOT, stdout: "inherit", stderr: "inherit" },
  );
  assert((await send.exited) === 0, "send-memo --mode transcribe reached notified (exit 0)");

  const call = (path: string) =>
    fetch(`${base}/v1${path}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const list = (await (await call("/memos?limit=1")).json()) as { items: { id: string }[] };
  const id = list.items[0]?.id;
  assert(id, "GET /memos?limit=1 returns the transcribe memo");
  const memo = (await (await call(`/memos/${id}`)).json()) as TypedMemo & {
    transcript: string | null;
    replyText: string | null;
  };
  assert(memo.mode === "transcribe", `memo keeps mode transcribe (got ${memo.mode})`);
  assert(memo.state === "notified", `transcribe memo is notified (got ${memo.state})`);
  assert(Boolean(memo.transcript), "transcribe memo carries the transcript");
  assert(memo.route === null, `transcribe memo has no route (got ${memo.route})`);
  assert(memo.replyText === null, "transcribe memo has no reply");
  assert(memo.summary === null, "transcribe memo has no summary");
  assert(
    memo.kind === undefined && memo.actions === undefined,
    "transcribe memo has no kind or actions",
  );
  const steps = memo.steps.map((step) => step.step).join(",");
  assert(steps === "transcribe,notify", `only transcribe and notify ran (got ${steps})`);

  const typed = await sendTyped(base, "So wie getippt.", "transcribe");
  assert(typed.state === "notified", `typed transcribe memo is notified (got ${typed.state})`);
  assert(typed.route === null, "typed transcribe memo has no route");
  const typedSteps = typed.steps.map((step) => step.step).join(",");
  assert(typedSteps === "notify", `a typed transcribe memo only notifies (got ${typedSteps})`);
  out("e2e: transcribe memo ok");
}

/** Every memo is a Hermes thread: a typed memo in the default mode reaches notified with Hermes's result and a thread id. */
async function probeHermesThread(base: string) {
  const memo = await sendTyped(
    base,
    "Was ist der Unterschied zwischen Mutex und Semaphor?",
    "hermes",
  );
  assert(memo.mode === "hermes", `memo keeps mode hermes (got ${memo.mode})`);
  assertHermesResult(memo);
  const { threadId } = memo;
  assert(
    typeof threadId === "string" && threadId !== "",
    `memo carries a threadId (got ${threadId})`,
  );
  out("e2e: hermes memo ok");
  await probeThreads(base, threadId);
  await probeLegacyModes(base);
}

/** The installed app still sends the older modes: they are stored as received and go to Hermes like any other. */
async function probeLegacyModes(base: string) {
  for (const mode of ["auto", "chat", "journal", "tab"]) {
    const memo = await sendTyped(base, "Notiere das bitte.", mode);
    assert(memo.mode === mode, `a ${mode} memo keeps its mode (got ${memo.mode})`);
    assertHermesResult(memo);
  }
  out("e2e: legacy modes ok");
}

interface ThreadWire {
  id: string;
  kind: string;
  lastMemoId: string | null;
}

/** Continues the chat memo's thread, then lists the threads and reads this one back with the conversation Iris recorded. */
async function probeThreads(base: string, threadId: string) {
  const continued = await sendTyped(base, "Und wann nehme ich welchen?", "hermes", threadId);
  assert(
    continued.threadId === threadId,
    `the reply stays in the thread (got ${continued.threadId})`,
  );

  const call = (path: string) =>
    fetch(`${base}/v1${path}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const list = (await (await call("/threads")).json()) as {
    items: ThreadWire[];
    nextCursor: string | null;
  };
  const listed = list.items.find((t) => t.id === threadId);
  assert(listed, `GET /threads lists the thread (got ${JSON.stringify(list.items)})`);
  assert(listed.kind === "hermes", `the thread is a hermes thread (got ${listed.kind})`);
  assert(list.items[0]?.id === threadId, "the continued thread is the newest update");

  const lastMemo = (await (await call("/memos?limit=1")).json()) as { items: { id: string }[] };
  assert(
    listed.lastMemoId === lastMemo.items[0]?.id,
    `the thread's last memo is the reply (got ${listed.lastMemoId})`,
  );

  const detailRes = await call(`/threads/${threadId}`);
  assert(detailRes.status === 200, `GET /threads/:id is 200 (got ${detailRes.status})`);
  const detail = (await detailRes.json()) as {
    thread: ThreadWire;
    memos: { id: string; threadId: string }[];
    messages: { memoId: string; role: string; content: string; createdAt: string }[];
  };
  assert(detail.memos.length === 2, `two memos ran in the thread (got ${detail.memos.length})`);
  assert(
    detail.memos.every((m) => m.threadId === threadId),
    "every memo carries the thread id",
  );
  const roles = detail.messages.map((m) => m.role).join(",");
  assert(
    roles === "user,assistant,user,assistant",
    `the conversation has both turns (got ${roles})`,
  );
  assert(
    detail.messages[2]?.content === "Und wann nehme ich welchen?",
    "the reply is the third message",
  );
  assert(detail.messages[3]?.content === "done", "the reply carries the assistant's answer");
  assert(
    detail.messages.map((m) => m.memoId).join() ===
      [threadId, threadId, continued.id, continued.id].join(),
    "each message names its memo",
  );
  assert(
    detail.messages.every((m) => m.createdAt),
    "each message is dated",
  );

  const missing = await call("/threads/does-not-exist");
  assert(missing.status === 404, `an unknown thread is 404 (got ${missing.status})`);
  out("e2e: threads ok");
}

async function main() {
  dataDir = await mkdtemp(join(tmpdir(), "iris-e2e-"));
  const port = freePort();
  const base = `http://127.0.0.1:${port}`;

  server = Bun.spawn(["bun", "server/src/index.ts"], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      IRIS_FAKES: "1",
      HOST: "127.0.0.1",
      PORT: String(port),
      IRIS_DATA: dataDir,
      IRIS_DEVICE_TOKENS: `${TOKEN}=e2e`,
      OTEL_EXPORTER_OTLP_ENDPOINT: "",
    },
  });
  void capture(server.stdout as ReadableStream<Uint8Array>);
  void capture(server.stderr as ReadableStream<Uint8Array>);

  await waitHealthy(base);
  const send = Bun.spawn(
    ["bun", "scripts/send-memo.ts", "fixtures/audio/de-90s.m4a", "--url", base, "--token", TOKEN],
    { cwd: ROOT, stdout: "inherit", stderr: "inherit" },
  );
  assert((await send.exited) === 0, "send-memo reached notified (exit 0)");
  await probe(base);
  await probeTyped(base);
  await probeHermesThread(base);
  await probeTranscribe(base);
}

async function cleanup() {
  server?.kill();
  await server?.exited;
  if (dataDir) await rm(dataDir, { recursive: true, force: true });
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => void cleanup().finally(() => process.exit(130)));
}

let failure: unknown;
try {
  await main();
} catch (error) {
  failure = error;
} finally {
  await cleanup();
}

if (failure) {
  err(`e2e FAILED: ${failure instanceof Error ? failure.message : String(failure)}`);
  err(`--- server output (last ${TAIL_LINES} lines) ---`);
  err(output.join("").split("\n").slice(-TAIL_LINES).join("\n"));
  process.exit(1);
}
out("e2e ok");
