import { Elysia, StatusMap } from "elysia";
import { recordSpan } from "../telemetry/otel.js";

// One server span per HTTP request: method, route template, status and duration, so API load and 4xx/5xx are readable in HyperDX.
// Attributes are those three only: never a path (it carries memo ids), a query, a header, a body or a device.

const startedAt = new WeakMap<Request, number>();

/** What a route that matched nothing is called, so a scanner's paths cannot make a span name per URL. */
const UNMATCHED = "unmatched";

/** The status the client got: a returned `Response` or `status()` carries its own, anything else the `set.status` the handlers and `onError` left. */
export function statusOf(response: unknown, setStatus: unknown): number {
  if (response instanceof Response) return response.status;
  if (typeof response === "object" && response !== null && "code" in response) {
    const { code } = response;
    if (typeof code === "number") return code;
  }
  if (typeof setStatus === "number") return setStatus;
  if (typeof setStatus === "string" && setStatus in StatusMap) {
    return StatusMap[setStatus as keyof typeof StatusMap];
  }
  return 200;
}

/**
 * Mount before the routes it measures. `GET /v1/events` is a stream: its request span ends when the headers are sent, the
 * stream's own lifetime is the `sse.stream` span (`http/events.ts`).
 */
export const requestTelemetry = new Elysia({ name: "request-telemetry" })
  .onRequest(({ request }) => {
    startedAt.set(request, performance.now());
  })
  .onAfterResponse({ as: "global" }, ({ request, route, response, set }) => {
    const started = startedAt.get(request);
    startedAt.delete(request);
    const status = statusOf(response, set.status);
    const template = route === "" || route === undefined ? UNMATCHED : route;
    recordSpan({
      name: `${request.method} ${template}`,
      kind: "server",
      durationMs: started === undefined ? 0 : performance.now() - started,
      attrs: {
        "http.request.method": request.method,
        "http.route": template,
        "http.response.status_code": status,
      },
      ...(status >= 500 && { error: `HTTP ${status}` }),
    });
  });
