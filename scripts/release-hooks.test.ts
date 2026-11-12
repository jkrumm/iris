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

describe.skipIf(!ready || !Bun.which("perl"))("release-hooks start", () => {
  const LAUNCHD_PATH = "/usr/bin:/bin"; // the poller's LaunchAgent PATH, less the user dirs

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "release-hooks-start-"));
    home = join(dir, "home");
    app = join(dir, "app");
    await mkdir(home, { recursive: true });
    await mkdir(join(dir, "Library", "Logs"), { recursive: true });
    await mkdir(app, { recursive: true });
    await writeFile(join(home, "release.env"), "MAC_RELEASE=1\n");
    git("init", "-q");
    await writeFile(join(app, "Makefile"), "mac-release:\n\t@true\n");
    await writeFile(join(dir, "factory-stub"), "#!/bin/sh\nexit 0\n");
    await chmod(join(dir, "factory-stub"), 0o755);
    // A stand-in for jobrun: records the PATH the job runs with.
    await writeFile(
      join(dir, "jobrun-stub"),
      `#!/bin/sh\nprintf '%s' "$PATH" > "${dir}/jobrun-path"\n`,
    );
    await chmod(join(dir, "jobrun-stub"), 0o755);
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  const logFile = () => join(dir, "Library", "Logs", "iris-release-mac.log");

  async function waitFor(file: string) {
    for (let i = 0; i < 100; i++) {
      if (await Bun.file(file).exists()) return;
      await Bun.sleep(100);
    }
    throw new Error(`${file} never appeared`);
  }

  // Runs the tick the way the poller's jobrun does: in a process group of its own that is SIGKILLed the moment the script exits.
  function tickThenKillGroup(sha: string) {
    return Bun.spawnSync(
      [
        "perl",
        "-MPOSIX",
        "-e",
        "POSIX::setsid(); system(@ARGV); kill 9, -$$",
        "--",
        "zsh",
        SCRIPT,
        sha,
      ],
      {
        env: {
          PATH: LAUNCHD_PATH,
          HOME: dir,
          RELEASE_HOME: home,
          APP_DIR: app,
          APPLE_LOCK: join(dir, "apple.lock"),
          FACTORY_BIN: join(dir, "factory-stub"),
          JOBRUN_BIN: join(dir, "jobrun-stub"),
        },
      },
    );
  }

  it("gives the job /usr/sbin (spctl) when the poller's PATH has none", async () => {
    const head = await commit("apple/a.swift", "1");
    tickThenKillGroup(head);
    await waitFor(join(dir, "jobrun-path"));
    expect((await readFile(join(dir, "jobrun-path"), "utf8")).split(":")).toContain("/usr/sbin");
  });

  it("the detached job survives the poller killing the script's process group", async () => {
    const head = await commit("apple/a.swift", "1");
    const r = tickThenKillGroup(head);
    await waitFor(join(dir, "jobrun-path"));
    const log = await readFile(logFile(), "utf8");
    expect(log).toContain("release: mac: detached job started");
    expect(r.stdout.toString()).toContain("mac detached job started (confirmed in its log)");
    expect(r.stdout.toString()).not.toContain("NOT");
  });

  it("says so when the detached job cannot be set up", async () => {
    const head = await commit("apple/a.swift", "1");
    await rm(join(dir, "Library"), { recursive: true });
    await writeFile(join(dir, "Library"), "not a directory"); // the log cannot be opened
    const r = tickThenKillGroup(head);
    expect(r.stdout.toString()).toContain("mac NOT started");
    expect(r.stdout.toString()).not.toContain("confirmed");
  });
});

describe.skipIf(!ready)("release-hooks --run", () => {
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "release-hooks-run-"));
    home = join(dir, "home");
    app = join(dir, "app");
    await mkdir(home, { recursive: true });
    await mkdir(app, { recursive: true });
    git("init", "-q");
    // A stand-in for apple-slot: records the slot run limit the build gets.
    await mkdir(join(app, "scripts"), { recursive: true });
    await writeFile(
      join(app, "scripts", "apple-slot"),
      `#!/bin/sh\nprintf '%s' "$FACTORY_SLOT_RUN_MS" > "${dir}/slot-run-ms"\n`,
    );
    await chmod(join(app, "scripts", "apple-slot"), 0o755);
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  it("lifts factory's 30 min slot run limit above the build's own timeout (rc 124 at 33 min)", async () => {
    const head = await commit("apple/a.swift", "1");
    const r = Bun.spawnSync(["zsh", SCRIPT, "--run", "mac", head], {
      env: { ...process.env, RELEASE_HOME: home, APP_DIR: app },
      stdout: "ignore", // the killed sampler leaves a `sleep` holding a pipe open
      stderr: "ignore",
    });
    expect(r.exitCode).toBe(0);
    expect(Number(await readFile(join(dir, "slot-run-ms"), "utf8"))).toBeGreaterThan(2400 * 1000);
  });
});
