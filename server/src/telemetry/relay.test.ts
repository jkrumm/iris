import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fakeOtlpExporter } from "./fakes.js";
import { buildRelayPayloads, createTelemetryRelay, type RelayBatch } from "./relay.js";

const fixture = (name: string): RelayBatch =>
  JSON.parse(readFileSync(join(import.meta.dir, "../../../contracts/fixtures", name), "utf8"));

const TRACE = "0f8fad5bd9cb469fa16570867728950e";

const first = <T>(items: T[]): T => {
  const [item] = items;
  if (item === undefined) throw new Error("expected a first item");
  return item;
};

describe("buildRelayPayloads", () => {
  it("turns the iOS fixture into OTLP traces and logs under the client's own resource", () => {
    const { traces, logs } = buildRelayPayloads(fixture("telemetry.request.json"));

    const resource = {
      attributes: [
        { key: "service.name", value: { stringValue: "iris-ios" } },
        { key: "service.version", value: { stringValue: "1.0.0" } },
        { key: "device.name", value: { stringValue: "Johannes' iPhone" } },
        { key: "deployment.environment", value: { stringValue: "test" } },
      ],
    };
    const scope = { name: "iris-ios" };
    expect(traces).toEqual({
      resourceSpans: [
        {
          resource,
          scopeSpans: [
            {
              scope,
              spans: [
                {
                  traceId: TRACE,
                  spanId: "00000000000000a1",
                  name: "capture",
                  kind: 1,
                  startTimeUnixNano: "1793102400000000000",
                  endTimeUnixNano: "1793102442500000000",
                  attributes: [],
                  status: { code: 1 },
                },
                {
                  traceId: TRACE,
                  spanId: "00000000000000a2",
                  parentSpanId: "00000000000000a1",
                  name: "segment.upload",
                  kind: 1,
                  startTimeUnixNano: "1793102410250000000",
                  endTimeUnixNano: "1793102411750000000",
                  attributes: [
                    { key: "segment", value: { intValue: "1" } },
                    { key: "attempt", value: { intValue: "2" } },
                    { key: "cached", value: { boolValue: false } },
                    { key: "ratio", value: { doubleValue: 0.5 } },
                    { key: "route", value: { stringValue: "audio/m4a" } },
                  ],
                  status: { code: 2 },
                },
              ],
            },
          ],
        },
      ],
    });
    expect(logs).toEqual({
      resourceLogs: [
        {
          resource,
          scopeLogs: [
            {
              scope,
              logRecords: [
                {
                  timeUnixNano: "1793102411800000000",
                  severityNumber: 13,
                  severityText: "WARN",
                  body: { stringValue: "outbox.retry" },
                  attributes: [
                    { key: "segment", value: { intValue: "1" } },
                    { key: "reason", value: { stringValue: "timeout" } },
                  ],
                  traceId: TRACE,
                },
                {
                  timeUnixNano: "1793102430000000000",
                  severityNumber: 9,
                  severityText: "INFO",
                  body: { stringValue: "app.foreground" },
                  attributes: [],
                },
              ],
            },
          ],
        },
      ],
    });
  });

  it("emits only the signal the batch has, and iris-macos for a Mac", () => {
    const payloads = buildRelayPayloads(fixture("telemetry.request.logs-only.json"));
    expect(payloads.traces).toBeUndefined();
    expect(JSON.stringify(payloads.logs)).toContain(
      '{"key":"service.name","value":{"stringValue":"iris-macos"}}',
    );
  });

  it("reads timestamps with no fraction and with a nanosecond fraction", () => {
    const batch = fixture("telemetry.request.logs-only.json");
    const nanos = (timestamp: string) => {
      const logs = [{ ...first(batch.logs), timestamp }];
      const json = JSON.stringify(buildRelayPayloads({ ...batch, logs }).logs);
      return /"timeUnixNano":"(\d+)"/.exec(json)?.[1];
    };
    expect(nanos("2026-10-27T12:00:00Z")).toBe("1793102400000000000");
    expect(nanos("2026-10-27T12:00:00.123456789Z")).toBe("1793102400123000000");
  });

  it("rejects a timestamp that is not a date before building anything", () => {
    const batch = fixture("telemetry.request.json");
    const broken = {
      ...batch,
      spans: [{ ...first(batch.spans), endTime: "2026-13-45T00:00:00Z" }],
    };
    expect(() => buildRelayPayloads(broken)).toThrow("spans/0/endTime: not a valid timestamp");
  });
});

const setup = (down = false) => {
  const exporter = fakeOtlpExporter({ down });
  const lines: Array<{ event: string; fields: Record<string, unknown> }> = [];
  const relay = createTelemetryRelay({
    exporter,
    log: (event, fields) => lines.push({ event, fields }),
  });
  return { exporter, lines, relay };
};

describe("createTelemetryRelay", () => {
  it("exports traces and logs separately and returns the counts", async () => {
    const { exporter, lines, relay } = setup();
    const accepted = relay.relay(fixture("telemetry.request.json"), "iphone");
    await relay.idle();
    expect(accepted).toEqual({ spans: 2, logs: 2 });
    expect(exporter.sent.map((s) => s.signal)).toEqual(["traces", "logs"]);
    expect(lines).toEqual([
      {
        event: "telemetry.relayed",
        fields: { device: "iphone", service: "iris-ios", spans: 2, logs: 2, dropped: 3 },
      },
    ]);
  });

  it("counts a failing exporter in a log line per signal and does not throw", async () => {
    const { lines, relay } = setup(true);
    const accepted = relay.relay(fixture("telemetry.request.json"), "iphone");
    await relay.idle();
    expect(accepted).toEqual({ spans: 2, logs: 2 });
    expect(lines.filter((l) => l.event === "telemetry.relay_failed")).toEqual([
      {
        event: "telemetry.relay_failed",
        fields: { signal: "traces", records: 2, error: "collector unreachable" },
      },
      {
        event: "telemetry.relay_failed",
        fields: { signal: "logs", records: 2, error: "collector unreachable" },
      },
    ]);
  });

  it("survives an exporter that throws synchronously", async () => {
    const lines: string[] = [];
    const relay = createTelemetryRelay({
      exporter: {
        send: () => {
          throw new Error("boom");
        },
      },
      log: (event) => lines.push(event),
    });
    expect(relay.relay(fixture("telemetry.request.logs-only.json"), "macbook")).toEqual({
      spans: 0,
      logs: 1,
    });
    await relay.idle();
    expect(lines).toEqual(["telemetry.relay_failed", "telemetry.relayed"]);
  });

  it("sends nothing and logs nothing when a timestamp is invalid", () => {
    const { exporter, lines, relay } = setup();
    const batch = fixture("telemetry.request.logs-only.json");
    const broken = {
      ...batch,
      logs: [{ ...first(batch.logs), timestamp: "2026-02-31T25:00:00Z" }],
    };
    expect(() => relay.relay(broken, "macbook")).toThrow();
    expect(exporter.sent).toEqual([]);
    expect(lines).toEqual([]);
  });
});
