import { afterEach, expect, it } from "bun:test";
import { join } from "node:path";

const repo = join(import.meta.dir, "..");
let server: ReturnType<typeof Bun.serve> | undefined;

afterEach(() => server?.stop(true));

// Only the refusing branch runs: an idle /health would kickstart the real agent.
it("make launchd-restart refuses while /health reports inflight work (a step running or a take in progress)", async () => {
  server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: () => Response.json({ status: "ok", degraded: [], inflight: 2 }),
  });
  const proc = Bun.spawn(
    ["make", "-C", repo, "launchd-restart", `HEALTH_URL=http://127.0.0.1:${server.port}/health`],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  expect(code).not.toBe(0);
  expect(out + err).toContain("refusing to restart: 2 memo(s) in flight or take(s) in progress");
});
