// Static server for the Playwright tests: the production build at `/`, the harness build at `/harness/`.
// It sends the header the real host sends with every bundled response, so the tests see the same policy.
import { extname, join, normalize } from "node:path";
import { HOST_POLICY } from "./policy";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".woff2": "font/woff2",
};

const webRoot = join(import.meta.dir, "..");

export function serve(port: number) {
  return Bun.serve({
    port,
    async fetch(request) {
      const { pathname } = new URL(request.url);
      const harness = pathname.startsWith("/harness/");
      const dir = join(webRoot, harness ? "dist-harness" : "dist");
      const rel = harness ? pathname.slice("/harness/".length) : pathname.slice(1);
      const name = rel === "" ? "index.html" : rel;
      if (!/^[A-Za-z0-9._-]+$/.test(name) || normalize(name) !== name) {
        return new Response("Not found", { status: 404 });
      }
      const file = Bun.file(join(dir, name));
      if (!(await file.exists())) return new Response("Not found", { status: 404 });
      return new Response(file, {
        headers: {
          "Content-Type": TYPES[extname(name)] ?? "application/octet-stream",
          "Content-Security-Policy": HOST_POLICY,
          "X-Content-Type-Options": "nosniff",
          "Cache-Control": "no-store",
        },
      });
    },
  });
}

if (import.meta.main) {
  const port = Number(process.env.PORT ?? 4173);
  serve(port);
  console.log(`serving on ${port}`);
}
