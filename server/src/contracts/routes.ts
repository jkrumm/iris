import { testApp } from "../http/test-support.js";
import { routeKey } from "./manifest.js";

/**
 * `METHOD /path` of every route the real app mounts. `createApp` builds the same Elysia instance
 * regardless of which adapters are injected, so the in-memory test app enumerates the production
 * route table; `app.routes` is Elysia's own registry (group prefixes included).
 */
export function appRoutes(): string[] {
  const { app, db } = testApp();
  const keys = app.routes.map(routeKey);
  db.close();
  return Array.from(new Set(keys)).toSorted();
}
