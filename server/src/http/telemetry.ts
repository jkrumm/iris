import { Elysia } from "elysia";
import { TypeCompiler } from "elysia/type-system";
import { configured, MemoError } from "../memo/errors.js";
import { TELEMETRY_MAX_BYTES, TELEMETRY_MAX_RECORDS } from "../telemetry/limits.js";
import type { TelemetryRelay } from "../telemetry/relay.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, TelemetryBatch, TelemetryResponse, TooLargeError } from "./schemas.js";

const checkBatch = TypeCompiler.Compile(TelemetryBatch);

/** Reads the body up to `max` bytes, stopping the stream as soon as it is over. */
async function readBounded(request: Request, max: number): Promise<string> {
  const tooLarge = () =>
    new MemoError("too_large", `telemetry batch exceeds ${max} bytes`, { maxBytes: max });
  if (Number(request.headers.get("content-length")) > max) throw tooLarge();

  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (let part = await reader.read(); !part.done; part = await reader.read()) {
    total += part.value.byteLength;
    if (total > max) {
      await reader.cancel();
      throw tooLarge();
    }
    chunks.push(part.value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseBatch(text: string) {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    throw new MemoError("bad_request", "unparseable request body");
  }
  if (!checkBatch.Check(json)) {
    const detail = checkBatch.Errors(json).First();
    throw new MemoError(
      "bad_request",
      detail ? `${detail.path || "request"}: ${detail.message}` : "invalid request",
    );
  }
  return json;
}

/**
 * `POST /telemetry`: the client span/log relay (TDD §8). The body is read and validated here rather than by
 * Elysia's parser so the guard answers 401 before any byte is read, and so an oversized body is cut off at the
 * limit. The records are exported in the background; the answer does not wait for the collector.
 */
export function telemetryRoutes(deps: {
  telemetry: TelemetryRelay | undefined;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { telemetry, auth } = deps;

  return new Elysia().use(auth).post(
    "/telemetry",
    async ({ request, device, set }) => {
      const relay = configured(telemetry, "telemetry");
      const batch = parseBatch(await readBounded(request, TELEMETRY_MAX_BYTES));
      if (batch.spans.length + batch.logs.length > TELEMETRY_MAX_RECORDS) {
        throw new MemoError(
          "bad_request",
          `a batch carries at most ${TELEMETRY_MAX_RECORDS} spans and logs together`,
        );
      }
      const accepted = relay.relay(batch, device as string);
      set.status = 202;
      return { accepted };
    },
    {
      // The handler streams and validates the body itself (see above).
      parse: "none",
      response: { 202: TelemetryResponse, 400: ErrorBody, 413: TooLargeError, 503: ErrorBody },
    },
  );
}
