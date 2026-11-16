import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("./xcb-retry", import.meta.url).pathname;

let dir = "";
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "xcb-retry-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

/** A fake xcodebuild: prints `first` on its first run and `second` on later ones, exiting with `codes`; counts its runs. */
function fake(first: string, firstCode: number, second = "", secondCode = 0): string {
  const body = `#!/usr/bin/env bash
n=$(cat "${dir}/runs" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "${dir}/runs"
if [ "$n" = 1 ]; then printf '%s\\n' "$FIRST"; exit ${firstCode}; fi
printf '%s\\n' "$SECOND"; exit ${secondCode}
`;
  const path = join(dir, "fake");
  writeFileSync(path, body, { mode: 0o755 });
  return path;
}

async function run(first: string, firstCode: number, second = "", secondCode = 0) {
  rmSync(join(dir, "runs"), { force: true });
  const path = fake(first, firstCode, second, secondCode);
  const proc = Bun.spawn(["bash", script, path], {
    env: { ...Bun.env, FIRST: first, SECOND: second, XCB_RETRY_PAUSE: "0" } as Record<
      string,
      string
    >,
    stdout: "pipe",
    stderr: "pipe",
  });
  const code = await proc.exited;
  const runs = Number(readFileSync(join(dir, "runs"), "utf8").trim());
  return { code, runs, out: await new Response(proc.stdout).text() };
}

describe("xcb-retry", () => {
  it("passes a green run through once", async () => {
    const result = await run("ok", 0);
    expect(result).toMatchObject({ code: 0, runs: 1 });
  });

  it("runs once more on a runner signature and returns the second run's exit code", async () => {
    const found =
      "xcodebuild: error: Unable to find a device matching the provided destination specifier:";
    expect(await run(found, 65, "all passed", 0)).toMatchObject({ code: 0, runs: 2 });
    expect(await run(found, 65, "still no device", 65)).toMatchObject({ code: 65, runs: 2 });
    const boot =
      "encountered an error (Early unexpected exit, operation never finished bootstrapping";
    expect(await run(boot, 65, "ok", 0)).toMatchObject({ code: 0, runs: 2 });
  });

  it("never runs a red test twice", async () => {
    const swiftTesting =
      'a stall\nunable to connect to "com.apple.instruments.deviceservice.lockdown"\n✘ Test "x" recorded an issue at A.swift:1:1: boom';
    expect(await run(swiftTesting, 65, "ok", 0)).toMatchObject({ code: 65, runs: 1 });
    const xctest =
      "/a/B.swift:70: error: -[IrisUITests.CaptureUITests testX] : XCTAssertTrue failed\noperation never finished bootstrapping";
    expect(await run(xctest, 65, "ok", 0)).toMatchObject({ code: 65, runs: 1 });
  });

  it("leaves an unrelated failure alone", async () => {
    expect(await run("error: no such scheme", 65, "ok", 0)).toMatchObject({ code: 65, runs: 1 });
  });
});
