import { z } from "zod";

// `contracts/manifest.json`: which schema, fixtures and media types belong to each route. Hand
// maintained on purpose: `check.ts` fails when it and the real app's routes disagree.

const JsonBody = z.strictObject({
  mediaType: z.literal("application/json"),
  schema: z.string(),
});

/** A body with no JSON schema: binary, plain text, empty or an event stream. */
const OtherBody = z.strictObject({
  mediaType: z.string().refine((type) => type !== "application/json", "JSON bodies need a schema"),
  description: z.string(),
});

const Body = z.union([JsonBody, OtherBody]);

const Route = z.strictObject({
  method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]),
  /** Elysia's path syntax (`:id`), without a trailing slash. */
  path: z.string().startsWith("/"),
  auth: z.enum(["bearer", "none"]),
  /** Schema name of the query string, when the route has one. */
  query: z.string().optional(),
  request: Body.optional(),
  /** Keyed by status code. */
  responses: z.record(z.string().regex(/^[0-9]{3}$/), Body),
  /** SSE only: the named events and the schema of each `data:` payload. */
  events: z.array(z.strictObject({ name: z.string(), schema: z.string() })).optional(),
});

export const Manifest = z.strictObject({
  description: z.string(),
  /** The guard's 401 on every bearer route. It is plain text, never JSON. */
  unauthorized: z.strictObject({
    status: z.literal(401),
    mediaType: z.literal("text/plain"),
    body: z.string(),
  }),
  routes: z.array(Route),
  /** Payloads the server sends through APNs; the apps decode them. */
  push: z.array(z.strictObject({ name: z.string(), schema: z.string(), notes: z.string() })),
});
export type Manifest = z.infer<typeof Manifest>;

export const routeKey = (route: { method: string; path: string }) =>
  `${route.method} ${route.path.length > 1 ? route.path.replace(/\/$/, "") : route.path}`;

/** Every JSON schema name the manifest points at. */
export function referencedSchemas(manifest: Manifest): Set<string> {
  const names = new Set<string>();
  const add = (body: z.infer<typeof Body> | undefined) => {
    if (body && "schema" in body) names.add(body.schema);
  };
  for (const route of manifest.routes) {
    if (route.query) names.add(route.query);
    add(route.request);
    for (const body of Object.values(route.responses)) add(body);
    for (const event of route.events ?? []) names.add(event.schema);
  }
  for (const entry of manifest.push) names.add(entry.schema);
  return names;
}
