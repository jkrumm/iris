import { env } from "../env.js";
import { MemoError } from "../memo/errors.js";
import { log as defaultLog } from "./log.js";
import { SEVERITY_NUMBER, SEVERITY_TEXT, STATUS_CODE, toOtlpAttributes } from "./otel.js";
import type { LogRecord, SpanRecord, StatusCode } from "./otel.js";
import type { LogSeverity } from "./otel-format.js";

// The client telemetry relay (TDD §8): a batch of spans and logs from the iOS or macOS app, re-emitted
// as OTLP JSON with the client's own resource (`service.name=iris-ios|iris-macos`). The memo trace id
// is kept as sent, so a phone span lands in the same trace as the server's `memo` span. The batch shape
// is `TelemetryBatch` in `http/schemas.ts`; the types here mirror it (the route passes the validated body).

type Attributes = Record<string, string | number | boolean>;

export interface RelaySpan {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: string;
  startTime: string;
  endTime: string;
  status: StatusCode;
  attributes: Attributes;
}

export interface RelayLog {
  timestamp: string;
  severity: LogSeverity;
  body: string;
  traceId?: string;
  attributes: Attributes;
}

export interface RelayBatch {
  resource: { serviceName: string; deviceName: string; appVersion: string };
  spans: RelaySpan[];
  logs: RelayLog[];
  dropped: number;
}

/** Port: ships one OTLP JSON payload to the collector. Rejects when the collector does not take it. */
export interface OtlpExporter {
  send(signal: "traces" | "logs", payload: object): Promise<void>;
}

export interface TelemetryRelay {
  /**
   * Converts and hands the batch to the exporter without waiting for it; a failing exporter is counted in
   * a `telemetry.relay_failed` log line, never thrown. Throws `bad_request` only for a timestamp that is
   * not a date, before anything is sent. `device` is the authenticated device, for the log lines.
   */
  relay(batch: RelayBatch, device: string): { spans: number; logs: number };
  /** Resolves once every export handed over so far has settled. */
  idle(): Promise<void>;
}

const nanos = (iso: string, where: string): string => {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) throw new MemoError("bad_request", `${where}: not a valid timestamp`);
  return (BigInt(ms) * 1_000_000n).toString();
};

function spanRecord(span: RelaySpan, index: number): SpanRecord {
  return {
    traceId: span.traceId,
    spanId: span.spanId,
    ...(span.parentSpanId && { parentSpanId: span.parentSpanId }),
    name: span.name,
    kind: 1,
    startTimeUnixNano: nanos(span.startTime, `spans/${index}/startTime`),
    endTimeUnixNano: nanos(span.endTime, `spans/${index}/endTime`),
    attributes: toOtlpAttributes(span.attributes),
    status: { code: STATUS_CODE[span.status] },
  };
}

function logRecord(entry: RelayLog, index: number): LogRecord {
  return {
    timeUnixNano: nanos(entry.timestamp, `logs/${index}/timestamp`),
    severityNumber: SEVERITY_NUMBER[entry.severity],
    severityText: SEVERITY_TEXT[entry.severity],
    body: { stringValue: entry.body },
    attributes: toOtlpAttributes(entry.attributes),
    ...(entry.traceId && { traceId: entry.traceId }),
  };
}

/** The OTLP resource every record of the batch shares. */
function resourceOf(resource: RelayBatch["resource"]) {
  return {
    scope: { name: resource.serviceName },
    resource: {
      attributes: toOtlpAttributes({
        "service.name": resource.serviceName,
        "service.version": resource.appVersion,
        "device.name": resource.deviceName,
        "deployment.environment": env.NODE_ENV,
      }),
    },
  };
}

/** Pure: the OTLP traces and logs payloads of a batch (each absent when the batch has none of that signal). */
export function buildRelayPayloads(batch: RelayBatch): { traces?: object; logs?: object } {
  const { scope, resource } = resourceOf(batch.resource);
  const spans = batch.spans.map(spanRecord);
  const logs = batch.logs.map(logRecord);
  return {
    ...(spans.length > 0 && {
      traces: { resourceSpans: [{ resource, scopeSpans: [{ scope, spans }] }] },
    }),
    ...(logs.length > 0 && {
      logs: { resourceLogs: [{ resource, scopeLogs: [{ scope, logRecords: logs }] }] },
    }),
  };
}

export function createTelemetryRelay(deps: {
  exporter: OtlpExporter;
  log?: (event: string, fields: Record<string, unknown>) => void;
}): TelemetryRelay {
  const { exporter } = deps;
  const log = deps.log ?? defaultLog;
  const pending = new Set<Promise<void>>();

  const ship = (params: { signal: "traces" | "logs"; payload: object; records: number }) => {
    // Async so the exporter is called now and a synchronous throw is caught like a rejection.
    const sent = (async () => {
      try {
        await exporter.send(params.signal, params.payload);
      } catch (err) {
        log("telemetry.relay_failed", {
          signal: params.signal,
          records: params.records,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    })().finally(() => pending.delete(sent));
    pending.add(sent);
  };

  return {
    relay(batch, device) {
      const payloads = buildRelayPayloads(batch);
      const { spans, logs } = { spans: batch.spans.length, logs: batch.logs.length };
      if (payloads.traces) ship({ signal: "traces", payload: payloads.traces, records: spans });
      if (payloads.logs) ship({ signal: "logs", payload: payloads.logs, records: logs });
      log("telemetry.relayed", {
        device,
        service: batch.resource.serviceName,
        spans,
        logs,
        dropped: batch.dropped,
      });
      return { spans, logs };
    },
    async idle() {
      await Promise.all(pending);
    },
  };
}
