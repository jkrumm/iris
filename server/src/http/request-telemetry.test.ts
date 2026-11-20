import { describe, expect, it } from "bun:test";
import { Elysia } from "elysia";
import { _test, type SpanRecord } from "../telemetry/otel.js";
import { PHONE, testApp } from "./test-support.js";
import { requestTelemetry, statusOf } from "./request-telemetry.js";

async function spansOf(fn: () => Promise<unknown>): Promise<SpanRecord[]> {
  const records: SpanRecord[] = [];
  _test.onSpanExport((r) => records.push(r));
  try {
    await fn();
    // `onAfterResponse` runs after the response is out.
    await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    _test.onSpanExport(null);
  }
  return records;
}

const attrs = (span: SpanRecord | undefined) =>
  Object.fromEntries(
    (span?.attributes ?? []).map((a) => [
      a.key,
      "intValue" in a.value ? Number(a.value.intValue) : Object.values(a.value)[0],
    ]),
  );

const get = (
  app: ReturnType<typeof testApp>["app"],
  path: string,
  headers: Record<string, string> = PHONE,
) => app.handle(new Request(`http://localhost${path}`, { headers }));

describe("request telemetry", () => {
  it("records method, route template and status of a served route, never the path", async () => {
    const { app } = testApp();
    const spans = await spansOf(() => get(app, "/v1/memos/00000000-0000-4000-8000-000000000001"));
    const span = spans.find((s) => s.name.startsWith("GET /v1/memos"));
    expect(span?.name).toBe("GET /v1/memos/:id");
    expect(span?.kind).toBe(2);
    expect(attrs(span)).toEqual({
      "http.request.method": "GET",
      "http.route": "/v1/memos/:id",
      "http.response.status_code": 404,
    });
    expect(span?.status.code).toBe(1);
    expect(JSON.stringify(spans)).not.toContain("00000000-0000-4000");
  });

  it("records an unauthenticated call as 401 and a route that does not exist as 404 unmatched", async () => {
    const { app } = testApp();
    const spans = await spansOf(async () => {
      await get(app, "/v1/whoami", {});
      await get(app, "/nope/a-secret-path", {});
    });
    expect(attrs(spans.find((s) => s.name === "GET /v1/whoami"))).toMatchObject({
      "http.response.status_code": 401,
    });
    const unmatched = spans.find((s) => s.name === "GET unmatched");
    expect(attrs(unmatched)).toMatchObject({
      "http.route": "unmatched",
      "http.response.status_code": 404,
    });
    expect(JSON.stringify(spans)).not.toContain("a-secret-path");
  });

  it("records a 200 with its duration", async () => {
    const { app } = testApp();
    const spans = await spansOf(() => get(app, "/health", {}));
    const health = spans.find((s) => s.name === "GET /health");
    expect(attrs(health)).toMatchObject({ "http.response.status_code": 200 });
    expect(BigInt(health?.endTimeUnixNano ?? 0)).toBeGreaterThanOrEqual(
      BigInt(health?.startTimeUnixNano ?? 1),
    );
  });

  it("measures from the request's arrival to the response", async () => {
    const app = new Elysia().use(requestTelemetry).get("/slow", async () => {
      await Bun.sleep(30);
      return "ok";
    });
    const spans = await spansOf(() => app.handle(new Request("http://localhost/slow")));
    const span = spans.find((s) => s.name === "GET /slow");
    const ms =
      Number(BigInt(span?.endTimeUnixNano ?? 0) - BigInt(span?.startTimeUnixNano ?? 0)) / 1e6;
    expect(ms).toBeGreaterThanOrEqual(25);
  });

  it("marks a 5xx as an errored span", async () => {
    const app = new Elysia().use(requestTelemetry).get("/boom", () => {
      throw new Error("kaboom");
    });
    const spans = await spansOf(() => app.handle(new Request("http://localhost/boom")));
    const span = spans.find((s) => s.name === "GET /boom");
    expect(attrs(span)).toMatchObject({ "http.response.status_code": 500 });
    expect(span?.status).toEqual({ code: 2, message: "HTTP 500" });
  });
});

describe("statusOf", () => {
  it("reads the status a returned Response, a status() object or set.status carries", () => {
    expect(statusOf(new Response("x", { status: 206 }), 200)).toBe(206);
    expect(statusOf({ code: 409, response: "conflict" }, 200)).toBe(409);
    expect(statusOf("ok", 503)).toBe(503);
    expect(statusOf("ok", "Not Found")).toBe(404);
    expect(statusOf("ok", undefined)).toBe(200);
  });
});
