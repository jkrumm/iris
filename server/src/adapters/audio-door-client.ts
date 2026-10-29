/** The response header naming the agent-workflows run that recorded the call, and its span / log key. */
export const RUN_ID_ATTR = "agw.run_id";
const RUN_ID_HEADER = "agw-run-id";

export interface AudioDoorClientOptions {
  /** The door base including the version segment: `http://127.0.0.1:7792/v1`. */
  baseUrl: string;
  /** The `iris` line of the door's caller-token file. */
  token: string;
  fetch?: typeof fetch;
}

export interface AudioDoorRequest {
  /** Path under the base, e.g. `/audio/speech`. */
  path: string;
  body: string | FormData;
  headers?: Record<string, string>;
  /** The hang guard of this call, not a budget. */
  timeoutMs: number;
}

export interface AudioDoorResponse {
  res: Response;
  /** `agw-run-id`: the run that records the call and its cost; null when the header is absent. */
  runId: string | null;
}

export interface AudioDoorClient {
  post(request: AudioDoorRequest): Promise<AudioDoorResponse>;
}

/**
 * The one way iris calls the agent-workflows audio door: URL normalisation, the bearer header, a hang
 * guard and the `agw-run-id` of the answer. A redirect is an error, so the bearer never follows one to
 * another host. Transport errors reach the caller untouched; each adapter classifies them.
 */
export function createAudioDoorClient(opts: AudioDoorClientOptions): AudioDoorClient {
  const doFetch = opts.fetch ?? fetch;
  const base = opts.baseUrl.replace(/\/+$/, "");

  return {
    async post({ path, body, headers, timeoutMs }) {
      const res = await doFetch(`${base}${path}`, {
        method: "POST",
        headers: { ...headers, authorization: `Bearer ${opts.token}` },
        body,
        redirect: "error",
        signal: AbortSignal.timeout(timeoutMs),
      });
      return { res, runId: res.headers.get(RUN_ID_HEADER) };
    },
  };
}
