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

  const herd = (await (await call("/herd")).json()) as { tabs?: unknown[] };
  assert(herd.tabs && herd.tabs.length >= 2, "GET /herd returns tabs");
  out(`e2e: R1 endpoints ok for memo ${id}`);
}

/** Parks a memo (mode tab with three live tabs asks "which tab?"), answers it with hermes, then corrects it after act. */
async function probeRoute(base: string) {
  const call = (path: string, init: RequestInit = {}) =>
    fetch(`${base}/v1${path}`, {
      ...init,
      headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    });
  const route = (id: string, destination: string) =>
    call(`/memos/${id}/route`, { method: "POST", body: JSON.stringify({ destination }) });

  const park = Bun.spawn(
    [
      "bun",
      "scripts/send-memo.ts",
      "fixtures/audio/de-90s.m4a",
      "--url",
      base,
      "--token",
      TOKEN,
      "--mode",
      "tab",
    ],
    { cwd: ROOT, stdout: "ignore", stderr: "ignore" },
  );
  assert((await park.exited) === 2, "send-memo --mode tab parks at needs_route (exit 2)");

  const list = (await (await call("/memos?limit=1")).json()) as { pinned: { id: string }[] };
  const id = list.pinned[0]?.id;
  assert(id, "GET /memos?limit=1 pins the parked memo");
  const parked = (await (await call(`/memos/${id}`)).json()) as {
    state: string;
    routeReason?: string;
  };
  assert(parked.state === "needs_route", `memo parks at needs_route (got ${parked.state})`);
  assert(
    parked.routeReason === "which tab?",
    `routeReason explains the park (got ${parked.routeReason})`,
  );

  const noTab = await route(id, "herdr");
  assert(noTab.status === 400, `answering herdr without a tab 400 (got ${noTab.status})`);

  const answer = await route(id, "hermes");
  assert(answer.status === 202, `answering hermes 202 (got ${answer.status})`);
  const done = await call(`/memos/${id}/result?wait=30`);
  const result = (await done.json()) as { state: string };
  assert(result.state === "notified", `answered memo reaches notified (got ${result.state})`);

  const again = await route(id, "hermes");
  assert(again.status === 200, `correction after act 200 (got ${again.status})`);
  out(`e2e: route answer and correction ok for memo ${id}`);
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
  assert(steps === "route,act,summarize,notify", `no ingest/transcribe rows (got ${steps})`);
  out(`e2e: typed memo ok for memo ${id}`);
}

interface TypedMemo {
  id: string;
  mode: string;
  state: string;
  route: string | null;
  threadId?: string;
  summary: { headline: string; detail: string; spoken: string } | null;
  steps: { step: string }[];
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

/** Mode journal: routed to the (fake) journal destination, summarized from the template. */
async function probeJournal(base: string) {
  const memo = await sendTyped(base, "Heute war ein guter Tag.", "journal");
  assert(memo.route === "journal", `mode journal routes to journal (got ${memo.route})`);
  assert(
    memo.summary?.headline === "Saved to journal",
    `journal summary is the template (got ${memo.summary?.headline})`,
  );
  assert(memo.summary.detail.startsWith("Heute"), "journal summary detail is the memo text");
  out("e2e: journal memo ok");
}

/** "tab server" names a fake tab; the prefix wins over the decider (mode `tab` alone parks, see probeRoute). */
async function probeTab(base: string) {
  const memo = await sendTyped(base, "tab server Starte die Tests.", "auto");
  assert(memo.route === "herdr", `a tab prefix routes to herdr (got ${memo.route})`);
  const { summary } = memo;
  assert(summary, "tab memo has a summary");
  assert(
    summary.headline.startsWith("Sent to"),
    `tab summary is the template (got ${summary.headline})`,
  );
  assert(
    summary.detail === "Starte die Tests.",
    `the delivered text has the prefix cut (got ${summary.detail})`,
  );
  out("e2e: tab memo ok");
}

/** Auto with no prefix and three destinations: the fake decider (hermes, 0.9) routes it. */
async function probeDecide(base: string) {
  const memo = await sendTyped(base, "Wie wird morgen das Wetter?", "auto");
  assert(memo.route === "hermes", `the fake decider routes to hermes (got ${memo.route})`);
  assert(memo.summary?.headline === "Headline", "hermes summary comes from the summarizer");
  out("e2e: decided memo ok");
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
  const steps = memo.steps.map((step) => step.step).join(",");
  assert(steps === "transcribe,notify", `only transcribe and notify ran (got ${steps})`);

  const typed = await sendTyped(base, "So wie getippt.", "transcribe");
  assert(typed.state === "notified", `typed transcribe memo is notified (got ${typed.state})`);
  assert(typed.route === null, "typed transcribe memo has no route");
  const typedSteps = typed.steps.map((step) => step.step).join(",");
  assert(typedSteps === "notify", `a typed transcribe memo only notifies (got ${typedSteps})`);
  out("e2e: transcribe memo ok");
}

/** A chat memo is a Hermes thread: it reaches notified and carries the thread id. */
async function probeChat(base: string) {
  const memo = await sendTyped(
    base,
    "Was ist der Unterschied zwischen Mutex und Semaphor?",
    "chat",
  );
  assert(memo.mode === "chat", `chat memo keeps mode chat (got ${memo.mode})`);
  assert(memo.route === "hermes", `chat memo routes to hermes (got ${memo.route})`);
  const { threadId } = memo;
  assert(
    typeof threadId === "string" && threadId !== "",
    `chat memo carries a threadId (got ${threadId})`,
  );
  out("e2e: chat memo ok");
  await probeThreads(base, threadId);
}

interface ThreadWire {
  id: string;
  kind: string;
  lastMemoId: string | null;
}

/** Continues the chat memo's thread, then lists the threads and reads this one back with the conversation Iris recorded. */
async function probeThreads(base: string, threadId: string) {
  const continued = await sendTyped(base, "Und wann nehme ich welchen?", "chat", threadId);
  assert(
    continued.threadId === threadId,
    `the reply stays in the thread (got ${continued.threadId})`,
  );
  assert(continued.route === "hermes", `a thread reply routes to hermes (got ${continued.route})`);

  const call = (path: string) =>
    fetch(`${base}/v1${path}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  const list = (await (await call("/threads?kind=chat")).json()) as {
    items: ThreadWire[];
    nextCursor: string | null;
  };
  const listed = list.items.find((t) => t.id === threadId);
  assert(listed, `GET /threads?kind=chat lists the thread (got ${JSON.stringify(list.items)})`);
  assert(listed.kind === "chat", `the thread is a chat (got ${listed.kind})`);
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
  await probeRoute(base);
  await probeTyped(base);
  await probeJournal(base);
  await probeTab(base);
  await probeDecide(base);
  await probeChat(base);
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
