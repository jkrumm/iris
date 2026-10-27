import { z } from "zod";

const Env = z.object({
  PORT: z.coerce.number().default(7730),
  // The mini pins 127.0.0.1 so only Caddy fronts it, never the LAN or a raw tailnet port.
  HOST: z.string().default("127.0.0.1"),
  // Audio segments and the SQLite file live here (`~/.iris/data` on the mini).
  IRIS_DATA: z.string().default("./data"),
  // `token=device,token=device` — see `parseDeviceTokens`. Empty means every /v1/* call is 401.
  IRIS_DEVICE_TOKENS: z.string().default(""),
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
