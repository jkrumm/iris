import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fakeOtlpExporter } from "../telemetry/fakes.js";
import { TELEMETRY_MAX_BYTES } from "../telemetry/limits.js";
import type { RelayBatch } from "../telemetry/relay.js";
import { call, MAC, testApp } from "./test-support.js";

const FIXTURES = join(import.meta.dir, "../../../contracts/fixtures");
const fixture = (name: string): RelayBatch =>
  JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));
const post = (
  app: ReturnType<typeof testApp>["app"],
  json: unknown,
  headers?: Record<string, string>,
) => call(app, { method: "POST", path: "/v1/telemetry", json, ...(headers && { headers }) });

const first = <T>(items: T[]): T => {
  const [item] = items;
  if (item === undefined) throw new Error("expected a first item");
  return item;
};

const patchSpan = (batch: RelayBatch, index: number, patch: object) => ({
  ...batch,
  spans: batch.spans.map((span, i) => (i === index ? { ...span, ...patch } : span)),
});
const patchLog = (batch: RelayBatch, index: number, patch: object) => ({
  ...batch,
  logs: batch.logs.map((entry, i) => (i === index ? { ...entry, ...patch } : entry)),
});

/** Posts the iOS fixture as changed by `change`: 400 `bad_request`, nothing exported. */
async function invalid(change: (batch: RelayBatch) => unknown) {
  const { app, otlp } = testApp();
  const res = await post(app, change(fixture("telemetry.request.json")));
  expect(res.status).toBe(400);
  expect(((await res.json()) as { error: string }).error).toBe("bad_request");
  expect(otlp.sent).toEqual([]);
}

describe("POST /v1/telemetry", () => {
  it("accepts the batch fixture, answers 202 with the counts and exports traces then logs", async () => {
    const { app, otlp, telemetry } = testApp();
    const res = await post(app, fixture("telemetry.request.json"));
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual(fixture("telemetry.response.json"));
    await telemetry.idle();

    expect(otlp.sent.map((s) => s.signal)).toEqual(["traces", "logs"]);
    const traces = JSON.stringify(otlp.sent[0]?.payload);
    expect(traces).toContain('{"key":"service.name","value":{"stringValue":"iris-ios"}}');
    expect(traces).toContain('"traceId":"0f8fad5bd9cb469fa16570867728950e"');
  });

  it("accepts a logs-only batch from the Mac and exports only logs", async () => {
    const { app, otlp, telemetry } = testApp();
    const res = await post(app, fixture("telemetry.request.logs-only.json"), MAC);
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ accepted: { spans: 0, logs: 1 } });
    await telemetry.idle();
    expect(otlp.sent.map((s) => s.signal)).toEqual(["logs"]);
    expect(JSON.stringify(otlp.sent[0]?.payload)).toContain('"stringValue":"iris-macos"');
  });

  it("logs the authenticated device and the dropped count", async () => {
    const { app, relayLog, telemetry } = testApp();
    await post(app, fixture("telemetry.request.json"), MAC);
    await telemetry.idle();
    expect(relayLog).toEqual([
      {
        event: "telemetry.relayed",
        fields: { device: "macbook", service: "iris-ios", spans: 2, logs: 2, dropped: 3 },
      },
    ]);
  });

  it("answers 202 and counts the failure in a log line when the collector is down", async () => {
    const { app, relayLog, telemetry } = testApp({ otlp: fakeOtlpExporter({ down: true }) });
    const res = await post(app, fixture("telemetry.request.json"));
    expect(res.status).toBe(202);
    await telemetry.idle();
    expect(relayLog.map((l) => l.event).toSorted()).toEqual([
      "telemetry.relay_failed",
      "telemetry.relay_failed",
      "telemetry.relayed",
    ]);
  });

  describe("auth", () => {
    it("is 401 without a token, and before the body is read", async () => {
      const { app, otlp } = testApp();
      const small = await post(app, fixture("telemetry.request.json"), {});
      expect(small.status).toBe(401);
      const huge = await call(app, {
        method: "POST",
        path: "/v1/telemetry",
        headers: { "content-length": String(TELEMETRY_MAX_BYTES + 1) },
        body: new Uint8Array(8),
      });
      expect(huge.status).toBe(401);
      expect(otlp.sent).toEqual([]);
    });

    it("is 401 for an unknown token", async () => {
      const { app } = testApp();
      const res = await post(app, fixture("telemetry.request.json"), {
        authorization: "Bearer nope",
      });
      expect(res.status).toBe(401);
    });
  });

  describe("bounds", () => {
    const tooLarge = {
      error: "too_large",
      message: `telemetry batch exceeds ${TELEMETRY_MAX_BYTES} bytes`,
      maxBytes: TELEMETRY_MAX_BYTES,
    };

    it("is 413 when content-length declares more than 256 KiB", async () => {
      const { app, otlp } = testApp();
      const res = await call(app, {
        method: "POST",
        path: "/v1/telemetry",
        headers: {
          authorization: "Bearer tok-phone",
          "content-length": String(TELEMETRY_MAX_BYTES + 1),
        },
        body: new Uint8Array(8),
      });
      expect(res.status).toBe(413);
      expect(await res.json()).toEqual(tooLarge);
      expect(otlp.sent).toEqual([]);
    });

    it("is 413 when the body is over 256 KiB without a content-length", async () => {
      const { app, otlp } = testApp();
      const batch = fixture("telemetry.request.json");
      const res = await post(app, {
        ...batch,
        logs: [{ ...first(batch.logs), body: "x".repeat(TELEMETRY_MAX_BYTES) }],
      });
      expect(res.status).toBe(413);
      expect(await res.json()).toEqual(tooLarge);
      expect(otlp.sent).toEqual([]);
    });

    it("takes exactly 500 spans and logs together and refuses 501", async () => {
      const { app, otlp, telemetry } = testApp();
      const batch = fixture("telemetry.request.json");
      const span = first(batch.spans);
      const entry = first(batch.logs);
      const sized = (spans: number, logs: number) => ({
        ...batch,
        spans: Array.from({ length: spans }, () => span),
        logs: Array.from({ length: logs }, () => entry),
      });

      const ok = await post(app, sized(250, 250));
      expect(ok.status).toBe(202);
      expect(await ok.json()).toEqual({ accepted: { spans: 250, logs: 250 } });
      await telemetry.idle();
      expect(otlp.sent).toHaveLength(2);

      const over = await post(app, sized(250, 251));
      expect(over.status).toBe(400);
      expect(await over.json()).toEqual({
        error: "bad_request",
        message: "a batch carries at most 500 spans and logs together",
      });
      expect((await post(app, sized(501, 0))).status).toBe(400);
      expect(otlp.sent).toHaveLength(2);
    });
  });

  describe("validation", () => {
    it("rejects an unknown service", () =>
      invalid((b) => ({ ...b, resource: { ...b.resource, serviceName: "iris-server" } })));
    it("rejects a trace id that is not 32 lowercase hex", () =>
      invalid((b) => patchSpan(b, 0, { traceId: "0F8FAD5B-D9CB-469F-A165-70867728950E" })));
    it("rejects a span id that is not 16 lowercase hex", () =>
      invalid((b) => patchSpan(b, 1, { parentSpanId: "abc" })));
    it("rejects a missing resource", () => invalid(({ resource: _resource, ...rest }) => rest));
    it("rejects a negative dropped count", () => invalid((b) => ({ ...b, dropped: -1 })));
    it("rejects a nested attribute value", () =>
      invalid((b) => patchLog(b, 0, { attributes: { nested: { a: 1 } } })));
    it("rejects a timestamp that is not ISO 8601 UTC", () =>
      invalid((b) => patchSpan(b, 0, { startTime: "27.10.2026 12:00" })));
    it("rejects a timestamp that matches the pattern but is not a date", () =>
      invalid((b) => patchLog(b, 1, { timestamp: "2026-13-45T00:00:00.000Z" })));

    it("rejects a body that is not JSON", async () => {
      const { app } = testApp();
      const res = await call(app, {
        method: "POST",
        path: "/v1/telemetry",
        body: new TextEncoder().encode("{not json"),
      });
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({
        error: "bad_request",
        message: "unparseable request body",
      });
    });
  });

  it("is 503 when the relay is not configured", async () => {
    const { app } = testApp({ telemetry: false });
    const res = await post(app, fixture("telemetry.request.json"));
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({
      error: "unavailable",
      message: "telemetry is not configured",
    });
  });
});
