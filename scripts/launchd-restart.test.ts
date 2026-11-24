import { afterEach, describe, expect, it } from "bun:test";
import { join } from "node:path";

const repo = join(import.meta.dir, "..");
let server: ReturnType<typeof Bun.serve> | undefined;

afterEach(() => server?.stop(true));

/** Runs the real `launchd-restart` target against a stubbed /health; only the refusing branches are exercised (an idle health would kickstart the agent). */
async function restartAgainst(health: Record<string, unknown>) {
  server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => Response.json(health) });
  const proc = Bun.spawn(
    ["make", "-C", repo, "launchd-restart", `HEALTH_URL=http://127.0.0.1:${server.port}/health`],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { out: out + err, code };
}

describe("make launchd-restart gate", () => {
  it("refuses while a take is receiving segments", async () => {
    const { out, code } = await restartAgainst({
      status: "ok",
      degraded: [],
      inflight: 0,
      receiving: 1,
    });
    expect(code).not.toBe(0);
    expect(out).toContain("refusing to restart: 1 take(s) in progress");
  });

  it("refuses while a memo is mid-step", async () => {
    const { out, code } = await restartAgainst({
      status: "ok",
      degraded: [],
      inflight: 2,
      receiving: 0,
    });
    expect(code).not.toBe(0);
    expect(out).toContain("refusing to restart: 2 memo(s) in flight");
  });
});
