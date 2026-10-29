import { z } from "zod";

const emptyToUndefined = (v: unknown) => (v === "" ? undefined : v);

const LOOPBACK_HOST = /^(localhost|127(\.\d{1,3}){3}|\[::1\])$/;

/** The bearer travels with every call, so the door is reached over TLS or on this machine only. */
const doorUrl = z.url().refine((v) => {
  // zod runs the refinement after a failed `url()` too.
  if (!URL.canParse(v)) return false;
  const { protocol, hostname } = new URL(v);
  return protocol === "https:" || (protocol === "http:" && LOOPBACK_HOST.test(hostname));
}, "AUDIO_DOOR_URL must be https or a loopback host (127.0.0.1, localhost, [::1]): the bearer token is sent with every request");

export const Env = z.object({
  PORT: z.coerce.number().default(7730),
  // The mini pins 127.0.0.1 so only Caddy fronts it, never the LAN or a raw tailnet port.
  HOST: z.string().default("127.0.0.1"),
  // Audio segments and the SQLite file live here (`~/.iris/data` on the mini).
  IRIS_DATA: z.string().default("./data"),
  // Per-segment upload cap; a 10 s m4a segment is well under 1 MB.
  IRIS_MAX_SEGMENT_BYTES: z.coerce.number().int().positive().default(5_000_000),
  // `token=device,token=device` — see `parseDeviceTokens`. Empty means every /v1/* call is 401.
  IRIS_DEVICE_TOKENS: z.string().default(""),
  // Downstream adapters. Each is optional: unset leaves its step without a handler (memos park)
  // and shows up in /health `degraded`.
  // The agent-workflows audio door (STT + TTS): base with the version segment, `http://127.0.0.1:7792/v1` on the
  // mini, and the caller token (`iris=` line of `~/.agent-workflows/data/door-tokens`, read by `launch.sh`). Both are
  // required for `transcribe` and `speech` to register.
  AUDIO_DOOR_URL: z.preprocess(emptyToUndefined, doorUrl.optional()),
  AUDIO_DOOR_TOKEN: z.preprocess(emptyToUndefined, z.string().optional()),
  AGW_URL: z.preprocess(emptyToUndefined, z.url().optional()),
  HERMES_URL: z.preprocess(emptyToUndefined, z.url().optional()),
  HERMES_TOKEN: z.preprocess(emptyToUndefined, z.string().optional()),
  // herdr's unix socket (`~/.config/herdr/herdr.sock` on the mini); unset leaves `GET /v1/herd` at 503 and the `herdr` destination unregistered.
  HERDR_SOCKET: z.preprocess(emptyToUndefined, z.string().optional()),
  // The brain git checkout (`~/SourceRoot/brain` on the mini); set registers the `journal` destination, which
  // writes notes into `Inbox/` and pushes. Unset leaves journal unregistered (not `degraded`).
  BRAIN_DIR: z.preprocess(emptyToUndefined, z.string().optional()),
  // APNs credentials. The APNs notifier needs all four (else the log notifier runs, which is not
  // `degraded`). `APNS_KEY_P8` is the .p8 PEM, literal `\n` escapes allowed; `APNS_TOPIC` the bundle id.
  APNS_KEY_P8: z.preprocess(emptyToUndefined, z.string().optional()),
  APNS_KEY_ID: z.preprocess(emptyToUndefined, z.string().optional()),
  APNS_TEAM_ID: z.preprocess(emptyToUndefined, z.string().optional()),
  APNS_TOPIC: z.preprocess(emptyToUndefined, z.string().optional()),
  // Boots every downstream port from in-memory fakes (`make e2e`). Never set in production;
  // scripts/launch.sh refuses to start with it. Empty = off.
  IRIS_FAKES: z.preprocess(emptyToUndefined, z.stringbool().default(false)),
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  // Optional with no default: unset keeps local dev and every test console-only.
  OTEL_EXPORTER_OTLP_ENDPOINT: z.preprocess((v) => (v === "" ? undefined : v), z.url().optional()),
  OTEL_RESOURCE_ATTRIBUTES: z.string().default(""),
  OTEL_SERVICE_NAME: z.string().default("iris-server"),
  OTEL_EXPORTER_OTLP_HEADERS: z.string().default(""),
  OTEL_EXPORTER_OTLP_AUTHORIZATION: z
    .string()
    .optional()
    .transform((v) => (v ? v : undefined)),
  OTEL_EXPORTER_OTLP_AUTH_SCHEME: z.string().default(""),
});

export const env = Env.parse(process.env);
