import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createSecureServer, type Http2Server, type ServerHttp2Stream } from "node:http2";
import type { IncomingHttpHeaders } from "node:http2";
import type { AddressInfo } from "node:net";
import type { ApnsMessage } from "../ports/apns.js";
import { buildAlert, buildLiveActivityUpdate } from "../notify/payloads.js";
import { seedMemo, testStore } from "../memo/test-support.js";
import { createNodeApnsTransport, MAX_INFLIGHT_STREAMS } from "./apns-node.js";
import { generateLocalhostCert, generateP8, verifyBearerJwt } from "./apns-test-support.js";

// The real transport (node-apn on Bun's node:http2) against a local TLS HTTP/2 server that plays
// APNs: it checks what goes over the wire, not a mock of the library.

const KEY_ID = "ABCDE12345";
const TEAM_ID = "TEAM123456";
const TOPIC = "com.example.iris";
const TOKEN = "0a1b2c3d4e5f60718293a4b5c6d7e8f9";

interface Seen {
  headers: IncomingHttpHeaders;
  body: string;
  startedAt: number;
}

const cert = await generateLocalhostCert();
// Without the openssl CLI the wire tests show up as skipped.
const p8 = await generateP8();

let server: Http2Server;
let port = 0;
const seen: Seen[] = [];
const timeline: ("start" | "end")[] = [];
let active = 0;
let maxActive = 0;
let respondWith: (headers: IncomingHttpHeaders) => { status: number; body?: object } = () => ({
  status: 200,
});
let delayMs = 0;

function reset() {
  seen.length = 0;
  timeline.length = 0;
  active = 0;
  maxActive = 0;
  delayMs = 0;
  respondWith = () => ({ status: 200 });
}

function handle(stream: ServerHttp2Stream, headers: IncomingHttpHeaders) {
  active++;
  maxActive = Math.max(maxActive, active);
  timeline.push("start");
  const chunks: Buffer[] = [];
  stream.on("data", (chunk: Buffer) => chunks.push(chunk));
  stream.on("end", () => {
    seen.push({ headers, body: Buffer.concat(chunks).toString(), startedAt: Date.now() });
    setTimeout(() => {
      const { status, body } = respondWith(headers);
      stream.respond({ ":status": status, "content-type": "application/json" });
      stream.end(body ? JSON.stringify(body) : undefined);
      active--;
      timeline.push("end");
    }, delayMs);
  });
}

function transport(overrides: { port?: number } = {}) {
  // node-apn hands `port` (default 443) to http2.connect and Bun honours it over the URL's port,
  // so a local server needs both the address and the port overridden.
  const local = {
    address: `localhost:${overrides.port ?? port}`,
    port: overrides.port ?? port,
    ca: [cert?.cert ?? ""],
  };
  return createNodeApnsTransport({
    keyP8: p8.pem,
    keyId: KEY_ID,
    teamId: TEAM_ID,
    providerOptions: { sandbox: local, production: local },
  });
}

const memo = { ...seedMemo(testStore().store, "summarized"), route: "hermes" };
const message: ApnsMessage = buildAlert({
  topic: TOPIC,
  memo,
  summary: { headline: "Buy milk", detail: "d", spoken: "s" },
});

const wire = describe.skipIf(!cert);

beforeAll(async () => {
  if (!cert) return;
  server = createSecureServer({
    key: cert.key,
    cert: cert.cert,
    settings: { maxConcurrentStreams: 100 },
  });
  server.on("stream", handle);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
});

afterAll(async () => {
  await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
});

wire("node-apn transport against a local HTTP/2 server", () => {
  it("sends the request APNs expects, signed with a verifiable ES256 token", async () => {
    reset();
    const t = transport();
    const result = await t.send({ ...message, environment: "sandbox", deviceToken: TOKEN });
    await t.close();

    expect(result).toEqual({ ok: true });
    expect(seen).toHaveLength(1);
    const request = seen[0] as Seen;
    expect(request.headers[":method"]).toBe("POST");
    expect(request.headers[":path"]).toBe(`/3/device/${TOKEN}`);
    expect(request.headers["apns-topic"]).toBe(TOPIC);
    expect(request.headers["apns-push-type"]).toBe("alert");
    expect(request.headers["apns-priority"]).toBe("10");
    expect(request.headers["apns-collapse-id"]).toBe(memo.id);
    expect(JSON.parse(request.body)).toEqual(message.payload);

    const jwt = await verifyBearerJwt(String(request.headers["authorization"]), p8.publicKey);
    expect(jwt.verified).toBe(true);
    expect(jwt.signatureBytes).toBe(64);
    expect(jwt.header).toEqual({ alg: "ES256", kid: KEY_ID, typ: "JWT" });
    expect(jwt.claims["iss"]).toBe(TEAM_ID);
    expect(Math.abs(Number(jwt.claims["iat"]) - Date.now() / 1000)).toBeLessThan(30);
  });

  it("maps Live Activity headers onto the wire", async () => {
    reset();
    const t = transport();
    const update = buildLiveActivityUpdate({ topic: TOPIC, memo, now: new Date() });
    await t.send({ ...update, environment: "production", deviceToken: TOKEN });
    await t.close();

    const request = seen[0] as Seen;
    expect(request.headers["apns-push-type"]).toBe("liveactivity");
    expect(request.headers["apns-topic"]).toBe(`${TOPIC}.push-type.liveactivity`);
    expect(request.headers["apns-priority"]).toBe("5");
    expect(request.headers["apns-expiration"]).toBeUndefined();
    expect(JSON.parse(request.body)).toEqual(update.payload);
  });

  it("sends expiration and collapse id when set", async () => {
    reset();
    const t = transport();
    await t.send({
      ...message,
      headers: { ...message.headers, expiration: 1767268800, collapseId: "memo-1" },
      environment: "sandbox",
      deviceToken: TOKEN,
    });
    await t.close();
    expect(seen[0]?.headers["apns-expiration"]).toBe("1767268800");
    expect(seen[0]?.headers["apns-collapse-id"]).toBe("memo-1");
  });

  it("never has more than 10 streams in flight, and sends the first request alone", async () => {
    reset();
    delayMs = 40;
    const t = transport();
    const results = await Promise.all(
      Array.from({ length: 15 }, () =>
        t.send({ ...message, environment: "sandbox", deviceToken: TOKEN }),
      ),
    );
    await t.close();

    expect(results.every((r) => r.ok)).toBe(true);
    expect(seen).toHaveLength(15);
    // The server allows 100 streams, so the cap held is ours: 15 sends, never more than 10 at once.
    expect(maxActive).toBe(MAX_INFLIGHT_STREAMS);
    expect(timeline.slice(0, 2)).toEqual(["start", "end"]);
  });

  it("maps APNs rejections to status and reason", async () => {
    reset();
    const t = transport();
    respondWith = () => ({ status: 410, body: { reason: "Unregistered", timestamp: 1 } });
    expect(await t.send({ ...message, environment: "sandbox", deviceToken: TOKEN })).toEqual({
      ok: false,
      status: 410,
      reason: "Unregistered",
    });
    respondWith = () => ({ status: 400, body: { reason: "BadDeviceToken" } });
    expect(await t.send({ ...message, environment: "sandbox", deviceToken: TOKEN })).toEqual({
      ok: false,
      status: 400,
      reason: "BadDeviceToken",
    });
    await t.close();
  });

  it("reports an unreachable server as status 0 instead of throwing", async () => {
    const dead = createSecureServer({ key: cert?.key ?? "", cert: cert?.cert ?? "" });
    await new Promise<void>((resolve) => dead.listen(0, "127.0.0.1", resolve));
    const deadPort = (dead.address() as AddressInfo).port;
    await new Promise<void>((resolve) => dead.close(() => resolve()));

    const t = transport({ port: deadPort });
    const result = await t.send({ ...message, environment: "sandbox", deviceToken: TOKEN });
    await t.close();
    expect(result).toMatchObject({ ok: false, status: 0 });
  });
});

describe("node-apn transport configuration", () => {
  it("reports an unusable key as status 0 instead of throwing", async () => {
    const t = createNodeApnsTransport({ keyP8: "not a key", keyId: KEY_ID, teamId: TEAM_ID });
    const result = await t.send({ ...message, environment: "sandbox", deviceToken: TOKEN });
    expect(result).toMatchObject({ ok: false, status: 0 });
    await t.close();
  });
});
