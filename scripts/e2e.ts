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

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`assertion failed: ${message}`);
}

function freePort(): number {
  const probe = Bun.serve({ port: 0, fetch: () => new Response() });
  const port = probe.port;
  void probe.stop(true);
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
  console.log(`e2e: R1 endpoints ok for memo ${id}`);
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
  console.error(`e2e FAILED: ${failure instanceof Error ? failure.message : String(failure)}`);
  console.error(`--- server output (last ${TAIL_LINES} lines) ---`);
  console.error(output.join("").split("\n").slice(-TAIL_LINES).join("\n"));
  process.exit(1);
}
console.log("e2e ok");
