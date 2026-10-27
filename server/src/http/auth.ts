import { Elysia } from "elysia";
import { createHash, timingSafeEqual } from "node:crypto";

/** Parse `token=device,token=device` into a token → device-name map. Blank entries are skipped. */
export function parseDeviceTokens(raw: string): Map<string, string> {
  const tokens = new Map<string, string>();
  for (const pair of raw.split(",")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    const token = pair.slice(0, eq).trim();
    const device = pair.slice(eq + 1).trim();
    if (token && device) tokens.set(token, device);
  }
  return tokens;
}

const digest = (s: string) => createHash("sha256").update(s).digest();

/**
 * Resolve a bearer token to its device name. Every candidate is compared in constant time over
 * a SHA-256 digest, so differing lengths do not leak the token length.
 */
export function deviceForToken(tokens: Map<string, string>, token: string): string | null {
  const probe = digest(token);
  let device: string | null = null;
  for (const [known, name] of tokens) {
    if (timingSafeEqual(probe, digest(known))) device = name;
  }
  return device;
}

/**
 * Bearer guard for `/v1/*`. Auth runs in `onTransform` (before schema validation) so an
 * unauthenticated request never reaches the validator. `as: "scoped"` propagates it to sibling
 * plugins mounted after the guard. Derives `device` for downstream handlers.
 */
export function deviceAuth(tokens: Map<string, string>) {
  return new Elysia({ name: "device-auth" })
    .derive({ as: "scoped" }, ({ request }) => {
      const header = request.headers.get("authorization");
      const token = header?.startsWith("Bearer ") ? header.slice(7) : "";
      return { device: token ? deviceForToken(tokens, token) : null };
    })
    .onTransform({ as: "scoped" }, ({ device, status }) => {
      if (!device) throw status(401, "Unauthorized");
    });
}
