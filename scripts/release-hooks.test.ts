import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "release-hooks.sh");
const ready = Boolean(
  Bun.which("zsh") && Bun.which("git") && Bun.which("jq") && Bun.which("lockf"),
);
const HOUR = 3600;

let dir: string;
let home: string;
let app: string;

function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", app, ...args], {
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "t",
      GIT_AUTHOR_EMAIL: "t@example.com",
      GIT_COMMITTER_NAME: "t",
      GIT_COMMITTER_EMAIL: "t@example.com",
    },
  });
  if (r.exitCode !== 0) throw new Error(r.stderr.toString());
  return r.stdout.toString().trim();
}

async function commit(file: string, body: string) {
  await mkdir(join(app, file, ".."), { recursive: true });
  await writeFile(join(app, file), body);
  git("add", "-A");
  git("commit", "-q", "-m", `change ${file} ${body}`);
  return git("rev-parse", "HEAD");
}

async function setMarker(hook: "testflight" | "mac-release", sha: string, ageSecs: number) {
  const file = join(home, `${hook}-sha`);
  await writeFile(file, `${sha}\n`);
  const t = new Date(Date.now() - ageSecs * 1000);
  await utimes(file, t, t);
}

function decide(sha: string, env: Record<string, string> = {}) {
  const r = Bun.spawnSync(["zsh", SCRIPT, sha], {
    env: {
      ...process.env,
      DRY_RUN: "1",
      RELEASE_HOME: home,
      APP_DIR: app,
      APPLE_LOCK: join(dir, "apple.lock"),
      FACTORY_BIN: join(dir, "factory-stub"),
      ...env,
    },
  });
  return r.stdout.toString() + r.stderr.toString();
}

// A stand-in for `factory slot run`: exits with <rc> (75 = no test slot free) without running the command.
async function writeStub(rc: number) {
  const file = join(dir, "factory-stub");
  await writeFile(file, `#!/bin/sh\nexit ${rc}\n`);
  await chmod(file, 0o755);
}

const starts = (out: string, hook: string) =>
  out.split("\n").filter((l) => l.includes(`${hook} DRY_RUN would start`)).length;

describe.skipIf(!ready)("release-hooks gate", () => {
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "release-hooks-test-"));
    home = join(dir, "home");
    app = join(dir, "app");
    await mkdir(home, { recursive: true });
    await mkdir(app, { recursive: true });
    await writeFile(join(home, "release.env"), "TESTFLIGHT=1\nMAC_RELEASE=1\n");
    git("init", "-q");
    await writeFile(join(app, "Makefile"), "mac-release:\n\t@true\n");
    await writeStub(0);
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  it("several apple/ commits in a day start one release per hook", async () => {
    const base = await commit("apple/a.swift", "1");
    await setMarker("testflight", base, 13 * HOUR);
    await setMarker("mac-release", base, 13 * HOUR);
    await commit("apple/a.swift", "2");
    await commit("apple/b.swift", "3");
    const head = await commit("apple/a.swift", "4");
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(1);
    expect(starts(out, "mac")).toBe(1);
  });

  it("starts whatever the hour: only the interval, the Apple lock and the slots gate", async () => {
    const base = await commit("apple/a.swift", "1");
    await setMarker("testflight", base, 13 * HOUR);
    await setMarker("mac-release", base, 13 * HOUR);
    const head = await commit("apple/a.swift", "2");
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(1);
    expect(starts(out, "mac")).toBe(1);
    expect(out).not.toContain("night");
  });

  it("waits until the last release is 12 hours old", async () => {
    const base = await commit("apple/a.swift", "1");
    await setMarker("testflight", base, 11 * HOUR);
    await setMarker("mac-release", base, 11 * HOUR);
    const head = await commit("apple/a.swift", "2");
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(0);
    expect(starts(out, "mac")).toBe(0);
    expect(out).toContain("minimum 12 h between automatic releases");
  });

  it("does not run without an apple/ change", async () => {
    const base = await commit("apple/a.swift", "1");
    await setMarker("testflight", base, 13 * HOUR);
    await setMarker("mac-release", base, 13 * HOUR);
    const head = await commit("server/x.ts", "2");
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(0);
    expect(starts(out, "mac")).toBe(0);
  });

  it("keeps the weekly TestFlight rebuild, not a Mac one", async () => {
    const head = await commit("apple/a.swift", "1");
    await setMarker("testflight", head, 8 * 24 * HOUR);
    await setMarker("mac-release", head, 8 * 24 * HOUR);
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(1);
    expect(out).toContain("weekly rebuild");
    expect(starts(out, "mac")).toBe(0);
  });

  it("starts the first release (no marker) when the machine is free", async () => {
    const head = await commit("apple/a.swift", "1");
    expect(starts(decide(head), "testflight")).toBe(1);
  });

  it("waits while the factory test slots are busy", async () => {
    const head = await commit("apple/a.swift", "1");
    await writeStub(75);
    const out = decide(head);
    expect(starts(out, "testflight")).toBe(0);
    expect(out).toContain("the factory test slots are busy");
  });

  it("waits while the Apple lock is held", async () => {
    const head = await commit("apple/a.swift", "1");
    const lock = join(dir, "apple.lock");
    const holder = Bun.spawn(["lockf", lock, "sleep", "20"]);
    try {
      await Bun.sleep(300);
      const out = decide(head);
      expect(starts(out, "testflight")).toBe(0);
      expect(out).toContain("the Apple lock is held");
    } finally {
      holder.kill();
      await holder.exited;
    }
  });
});

describe.skipIf(!ready)("release-hooks --record-peak", () => {
  let state: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "release-hooks-peak-"));
    home = join(dir, "home");
    await mkdir(home, { recursive: true });
    state = join(dir, "com.jkrumm.iris-release-mac.json");
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  const record = (began: number) =>
    Bun.spawnSync(["zsh", SCRIPT, "--record-peak", "mac", String(began)], {
      env: { ...process.env, RELEASE_HOME: home, JOBS_STATE_DIR: dir },
    });

  it("adds the peak (MB) to a state written during the wrapper", async () => {
    const began = Math.floor(Date.now() / 1000) - 10;
    await writeFile(
      state,
      JSON.stringify({ run_id: "r1", started: new Date().toISOString(), rc: 0 }),
    );
    await writeFile(join(home, "peak-mac.kb"), "5242880\n");
    expect(record(began).exitCode).toBe(0);
    const j = JSON.parse(await readFile(state, "utf8"));
    expect(j.peak_rss_mb).toBe(5120);
    expect(j.peak_rss_run_id).toBe("r1");
    expect(await Bun.file(join(home, "peak-mac.kb")).exists()).toBe(false);
  });

  it("leaves a state older than the wrapper alone (jobrun skipped on its lock)", async () => {
    const began = Math.floor(Date.now() / 1000);
    await writeFile(
      state,
      JSON.stringify({
        run_id: "old",
        started: new Date(Date.now() - 3600_000).toISOString(),
        rc: 0,
      }),
    );
    await writeFile(join(home, "peak-mac.kb"), "1024\n");
    expect(record(began).exitCode).toBe(0);
    expect(JSON.parse(await readFile(state, "utf8")).peak_rss_mb).toBeUndefined();
    expect(await Bun.file(join(home, "peak-mac.kb")).exists()).toBe(true);
  });
});
