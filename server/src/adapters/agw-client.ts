import { z } from "zod";
import { fetchFailure, hangGuardFailure, httpFailure } from "../ports/transient.js";
import { withSpan } from "../telemetry/otel.js";
import { RUN_ID_ATTR } from "./audio-door-client.js";

const RUN_ID_HEADER = "agw-run-id";
const BODY_MAX = 300;
// Names iris on the run record; a label, not a scope.
const PURPOSE = "iris";

export interface AgwClientOptions {
  /** The agent-workflows host: `http://127.0.0.1:7791`. */
  baseUrl: string;
  /** `AGW_API_SECRET`, the host's one bearer. */
  secret: string;
  fetch?: typeof fetch;
  /** The hang guard of a call, not a budget; tests shorten it. */
  timeoutMs?: number;
}

export interface AgwCall<T extends z.ZodType> {
  memoId: string;
  /** Capability path on the host, e.g. `/triage`. */
  path: string;
  body: unknown;
  /** Validates the 200 body. */
  schema: T;
}

export interface AgwResult<T> {
  data: T;
  /** `agw-run-id`, the run that records the call and its cost; null when the header is absent. */
  runId: string | null;
}

export interface AgwClient {
  call<T extends z.ZodType>(call: AgwCall<T>): Promise<AgwResult<z.infer<T>>>;
}

// A hang guard, not a budget: a model call can be slow, and cutting it off turns a slow answer into a failure.
const DEFAULT_TIMEOUT_MS = 1_800_000;

/**
 * The one way iris calls the agent-workflows host's capabilities: a synchronous `POST` with the bearer,
 * `x-agw-purpose: iris`, no redirects (the bearer never follows one to another host) and the
 * `agw-run-id` of every answer, errors included. The hang guard aborts the request, which cancels
 * the run and the provider call on the host. 400, 401 and 502 `INVALID_OUTPUT` are final; 500, 503
 * and a lost connection are transient (the runner retries); the guard firing is a `hangGuardFailure`.
 */
export function createAgwClient(opts: AgwClientOptions): AgwClient {
  const doFetch = opts.fetch ?? fetch;
  const base = opts.baseUrl.replace(/\/+$/, "");
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  // The guard covers the body too: a timeout while it streams is the same hang.
  const hungOr = (what: string, err: unknown): unknown =>
    err instanceof Error && err.name === "TimeoutError"
      ? hangGuardFailure(`agw ${what} timed out after ${timeoutMs} ms`, { cause: err })
      : fetchFailure(err);

  return {
    async call({ memoId, path, body, schema }) {
      const what = path.replace(/^\//, "");
      return withSpan(`agw.${what}`, { memo_id: memoId, downstream: "agw" }, async (span) => {
        const res = await doFetch(`${base}${path}`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${opts.secret}`,
            "x-agw-purpose": PURPOSE,
          },
          body: JSON.stringify(body),
          redirect: "error",
          signal: AbortSignal.timeout(timeoutMs),
        }).catch((err: unknown) => {
          throw hungOr(what, err);
        });
        const runId = res.headers.get(RUN_ID_HEADER);
        span.setAttributes({ status: res.status, [RUN_ID_ATTR]: runId });

        if (!res.ok) {
          const text = (await res.text().catch(() => "")).slice(0, BODY_MAX);
          // 502 INVALID_OUTPUT: the model failed twice, another call would only pay again.
          const message = `agw ${what} failed: ${res.status}${runId ? ` (run ${runId})` : ""} ${text}`;
          throw res.status === 502 ? new Error(message) : httpFailure(message, res.status);
        }

        const json: unknown = await res.json().catch((err: unknown) => {
          throw hungOr(what, err);
        });
        const parsed = schema.safeParse(json);
        if (!parsed.success) {
          const issues = parsed.error.issues
            .map((issue) => `${issue.path.join(".") || "result"}: ${issue.message}`)
            .join("; ");
          throw new Error(
            `agw ${what} response does not match its schema${runId ? ` (run ${runId})` : ""}: ${issues}`,
          );
        }
        return { data: parsed.data, runId };
      });
    },
  };
}
