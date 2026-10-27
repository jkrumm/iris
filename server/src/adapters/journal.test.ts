import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fixedClock } from "../ports/clock.js";
import {
  bunGitRunner,
  createGitRunner,
  createJournalDestination,
  journalSlug,
  journalTitle,
  type GitResult,
  type JournalDestinationOptions,
} from "./journal.js";

const MEMO_A = "0f8fad5b-d9cb-469f-a165-70867728950e";
const MEMO_B = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
// No zone suffix: parsed as local time, so the note date is the same in any TZ.
const clock = fixedClock("2026-03-05T10:00:00");

interface Vault {
  root: string;
  brain: string;
  remote: string;
  lockDir: string;
}

let vault: Vault;

async function git(cwd: string, ...args: string[]): Promise<string> {
  const result = await bunGitRunner(args, cwd);
  if (result.code !== 0) throw new Error(`git ${args.join(" ")}: ${result.stderr}`);
  return result.stdout;
}

beforeEach(async () => {
  const root = await mkdtemp(join(tmpdir(), "iris-journal-"));
  const brain = join(root, "brain");
  const remote = join(root, "remote.git");
  await mkdir(brain);
  await mkdir(remote);
  await git(remote, "init", "--bare", "-b", "main");
  await git(brain, "init", "-b", "main");
  await git(brain, "config", "user.name", "Test");
  await git(brain, "config", "user.email", "test@example.com");
  await git(brain, "config", "commit.gpgsign", "false");
  await git(brain, "remote", "add", "origin", remote);
  await writeFile(join(brain, "README.md"), "vault\n");
  await git(brain, "add", "README.md");
  await git(brain, "commit", "-m", "init");
  await git(brain, "push", "-u", "origin", "main");
  vault = { root, brain, remote, lockDir: join(root, "brain-sync.lock") };
});

afterEach(async () => {
  await rm(vault.root, { recursive: true, force: true });
});

const journal = (extra: Partial<JournalDestinationOptions> = {}) =>
  createJournalDestination({
    brainDir: vault.brain,
    clock,
    lockDir: vault.lockDir,
    lockBaseDelayMs: 5,
    lockAttempts: 3,
    ...extra,
  });

const read = (ref: string) => readFile(join(vault.brain, ref), "utf8");
const commitCount = async (cwd: string) =>
  Number((await git(cwd, "rev-list", "--count", "HEAD")).trim());

describe("journal title and slug", () => {
  it("takes the first sentence, clipped on a word boundary", () => {
    expect(journalTitle("Buy milk, eggs and bread. Then call Anna.")).toBe(
      "Buy milk, eggs and bread",
    );
    const long = journalTitle(
      "Remember to talk about the quarterly planning with the whole platform team next week",
    );
    expect(long).toBe("Remember to talk about the quarterly planning with the whole");
    expect(long.length).toBeLessThanOrEqual(60);
    expect(journalTitle("x".repeat(100))).toBe("x".repeat(60));
    expect(journalTitle("  \n ")).toBe("Voice memo");
  });

  it("spells umlauts out, folds other diacritics and falls back to memo", () => {
    expect(journalSlug("Größe für Märchen, Öl & Café")).toBe("groesse-fuer-maerchen-oel-cafe");
    expect(journalSlug("!!! ???")).toBe("memo");
    expect(journalSlug("")).toBe("memo");
    const long = journalSlug("word ".repeat(30));
    expect(long.length).toBeLessThanOrEqual(50);
    expect(long.endsWith("-")).toBe(false);
  });
});

describe("journal destination", () => {
  it("writes the note with exact frontmatter, commits and pushes it", async () => {
    const delivery = await journal().deliver({
      memoId: MEMO_A,
      transcript: "Buy milk, eggs and bread. Then call Anna.",
    });
    expect(delivery).toEqual({ ref: "Inbox/2026-03-05-buy-milk-eggs-and-bread.md", replyText: "" });
    expect(await read(delivery.ref)).toBe(
      [
        "---",
        'title: "Buy milk, eggs and bread"',
        "date: 2026-03-05",
        "tags: [journal, iris]",
        "source: iris",
        `memo: ${MEMO_A}`,
        "---",
        "",
        "Buy milk, eggs and bread. Then call Anna.",
        "",
      ].join("\n"),
    );

    expect((await git(vault.brain, "log", "-1", "--format=%s")).trim()).toBe(
      "journal: Buy milk, eggs and bread",
    );
    expect((await git(vault.brain, "status", "--porcelain")).trim()).toBe("");
    expect(await git(vault.remote, "rev-parse", "main")).toBe(
      await git(vault.brain, "rev-parse", "HEAD"),
    );
  });

  it("releases the lock", async () => {
    await journal().deliver({ memoId: MEMO_A, transcript: "Hello." });
    expect(await readdir(vault.root)).not.toContain("brain-sync.lock");
  });

  it("names a memo without usable words memo", async () => {
    const { ref } = await journal().deliver({ memoId: MEMO_A, transcript: "!!!" });
    expect(ref).toBe("Inbox/2026-03-05-memo.md");
  });

  it("appends the memo id prefix when another memo owns the file name", async () => {
    const destination = journal();
    const first = await destination.deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    const second = await destination.deliver({ memoId: MEMO_B, transcript: "Call Anna." });
    expect(first.ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect(second.ref).toBe("Inbox/2026-03-05-call-anna-7c9e6679.md");
    expect(await read(first.ref)).toContain(`memo: ${MEMO_A}`);
    expect(await read(second.ref)).toContain(`memo: ${MEMO_B}`);
  });

  it("is idempotent on retry: same note, no second file, no second commit", async () => {
    const destination = journal();
    const first = await destination.deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    const commits = await commitCount(vault.brain);
    // A later retry may land on another day; the note found by its memo id is still the one.
    const later = journal({ clock: fixedClock("2026-03-07T09:00:00") });
    const second = await later.deliver({ memoId: MEMO_A, transcript: "Call Anna." });

    expect(second).toEqual(first);
    expect(await readdir(join(vault.brain, "Inbox"))).toEqual(["2026-03-05-call-anna.md"]);
    expect(await commitCount(vault.brain)).toBe(commits);
  });

  it("commits a note a failed earlier attempt left behind", async () => {
    let failCommit = true;
    const flaky = journal({
      git: async (args, cwd, opts) =>
        failCommit && args[0] === "commit"
          ? { code: 1, stdout: "", stderr: "boom" }
          : bunGitRunner(args, cwd, opts),
    });
    await expect(flaky.deliver({ memoId: MEMO_A, transcript: "Call Anna." })).rejects.toThrow(
      "git commit failed: boom",
    );
    failCommit = false;

    const { ref } = await flaky.deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    expect((await git(vault.brain, "log", "-1", "--format=%s")).trim()).toBe("journal: Call Anna");
    expect(await git(vault.brain, "ls-files", ref)).toBe(`${ref}\n`);
    expect(await readdir(join(vault.brain, "Inbox"))).toHaveLength(1);
  });

  it("commits only its own file when the vault has other dirt", async () => {
    await writeFile(join(vault.brain, "README.md"), "edited\n");
    await writeFile(join(vault.brain, "untracked.md"), "scratch\n");
    await writeFile(join(vault.brain, "staged.md"), "staged\n");
    await git(vault.brain, "add", "staged.md");

    const { ref } = await journal().deliver({ memoId: MEMO_A, transcript: "Call Anna." });

    expect((await git(vault.brain, "show", "--name-only", "--format=", "HEAD")).trim()).toBe(ref);
    const status = (await git(vault.brain, "status", "--porcelain")).split("\n").filter(Boolean);
    expect(status.toSorted()).toEqual(
      [" M README.md", "?? untracked.md", "A  staged.md"].toSorted(),
    );
  });

  it("keeps the commit when the push fails", async () => {
    await rm(vault.remote, { recursive: true, force: true });
    const { ref } = await journal().deliver({ memoId: MEMO_A, transcript: "Call Anna." });

    expect((await git(vault.brain, "log", "-1", "--format=%s")).trim()).toBe("journal: Call Anna");
    expect(await git(vault.brain, "ls-files", ref)).toBe(`${ref}\n`);
  });

  it("passes the push timeout to the git runner", async () => {
    const seen: Array<number | undefined> = [];
    await journal({
      pushTimeoutMs: 1234,
      git: async (args, cwd, opts) => {
        if (args[0] === "push") seen.push(opts?.timeoutMs);
        return bunGitRunner(args, cwd, opts);
      },
    }).deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    expect(seen).toEqual([1234]);
  });

  it("releases the lock before it pushes", async () => {
    const lockHeldAtPush: boolean[] = [];
    await journal({
      git: async (args, cwd, opts) => {
        if (args[0] === "push")
          lockHeldAtPush.push((await readdir(vault.root)).includes("brain-sync.lock"));
        return bunGitRunner(args, cwd, opts);
      },
    }).deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    expect(lockHeldAtPush).toEqual([false]);
  });

  it("leaves no temp file behind and ignores one left by an interrupted write", async () => {
    await mkdir(join(vault.brain, "Inbox"));
    await writeFile(
      join(vault.brain, "Inbox", "2026-03-05-call-anna.md.tmp-1"),
      `---\nmemo: ${MEMO_A}\n---\n`,
    );
    const { ref } = await journal().deliver({ memoId: MEMO_A, transcript: "Call Anna." });
    expect(ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect((await readdir(join(vault.brain, "Inbox"))).toSorted()).toEqual([
      "2026-03-05-call-anna.md",
      "2026-03-05-call-anna.md.tmp-1",
    ]);
  });

  it("fails on an unreadable Inbox instead of writing a second note", async () => {
    const inbox = join(vault.brain, "Inbox");
    await mkdir(inbox);
    await chmod(inbox, 0o000);
    try {
      await expect(journal().deliver({ memoId: MEMO_A, transcript: "Call Anna." })).rejects.toThrow(
        /EACCES|permission denied/i,
      );
    } finally {
      await chmod(inbox, 0o755);
    }
    expect(await readdir(vault.root)).not.toContain("brain-sync.lock");
  });

  it("waits for a busy lock and proceeds once it is released", async () => {
    await mkdir(vault.lockDir);
    setTimeout(() => void rm(vault.lockDir, { recursive: true }), 20);
    const { ref } = await journal({ lockAttempts: 6 }).deliver({
      memoId: MEMO_A,
      transcript: "Call Anna.",
    });
    expect(ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect(await readdir(vault.root)).not.toContain("brain-sync.lock");
  });

  it("fails clearly when the lock stays busy, writes nothing and leaves the lock alone", async () => {
    await mkdir(vault.lockDir);
    const before = await commitCount(vault.brain);

    await expect(journal().deliver({ memoId: MEMO_A, transcript: "Call Anna." })).rejects.toThrow(
      /brain-sync lock is busy after 4 attempts/,
    );

    expect(await readdir(vault.brain)).not.toContain("Inbox");
    expect(await commitCount(vault.brain)).toBe(before);
    expect((await readdir(vault.root)).includes("brain-sync.lock")).toBe(true);
  });
});

const lockExists = async () => (await readdir(vault.root)).includes("brain-sync.lock");

async function holdLock(pid?: string, ageSeconds = 0) {
  await mkdir(vault.lockDir);
  if (pid !== undefined) await writeFile(join(vault.lockDir, "pid"), pid);
  const born = new Date(Date.now() - ageSeconds * 1000);
  await utimes(vault.lockDir, born, born);
}

/** A pid that is certainly gone: a child that has exited and been reaped. */
async function deadPid(): Promise<number> {
  const child = Bun.spawn(["true"]);
  await child.exited;
  return child.pid;
}

const deliver = (extra: Partial<JournalDestinationOptions> = {}) =>
  journal(extra).deliver({ memoId: MEMO_A, transcript: "Call Anna." });

describe("brain-sync lock protocol", () => {
  it("writes its own pid while it holds the lock and removes the lock after", async () => {
    const seen: Array<string | undefined> = [];
    await deliver({
      git: async (args, cwd, opts) => {
        if (args[0] === "add") {
          seen.push(await readFile(join(vault.lockDir, "pid"), "utf8").catch(() => undefined));
        }
        return bunGitRunner(args, cwd, opts);
      },
    });
    expect(seen).toEqual([String(process.pid)]);
    expect(await lockExists()).toBe(false);
  });

  it("waits for a live holder and never reclaims it", async () => {
    // The parent is alive for the whole test run and not us.
    await holdLock(String(process.ppid), 3600);
    await expect(deliver()).rejects.toThrow(/brain-sync lock is busy/);
    expect(await readFile(join(vault.lockDir, "pid"), "utf8")).toBe(String(process.ppid));
    expect(await readdir(vault.brain)).not.toContain("Inbox");
  });

  it("proceeds once a live holder lets go", async () => {
    await holdLock(String(process.ppid));
    setTimeout(() => void rm(vault.lockDir, { recursive: true }), 20);
    const { ref } = await deliver({ lockAttempts: 6 });
    expect(ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect(await lockExists()).toBe(false);
  });

  it("reclaims the lock of a dead pid, even a fresh one", async () => {
    await holdLock(String(await deadPid()));
    const { ref } = await deliver();
    expect(ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect(await lockExists()).toBe(false);
  });

  it("treats a pidless lock younger than 60 s as live", async () => {
    await holdLock(undefined, 30);
    await expect(deliver()).rejects.toThrow(/brain-sync lock is busy/);
    expect(await lockExists()).toBe(true);
    expect(await readdir(vault.brain)).not.toContain("Inbox");
  });

  it("reclaims a pidless lock of 60 s or more", async () => {
    await holdLock(undefined, 61);
    const { ref } = await deliver();
    expect(ref).toBe("Inbox/2026-03-05-call-anna.md");
    expect(await lockExists()).toBe(false);
  });

  it("treats a pid file that holds no pid like a pidless lock", async () => {
    await holdLock("garbage", 61);
    await deliver();
    expect(await lockExists()).toBe(false);
  });

  it("does not remove a lock someone else re-took while it worked", async () => {
    await deliver({
      git: async (args, cwd, opts) => {
        // brain-sync reclaimed our lock mid-delivery and now holds it.
        if (args[0] === "commit") await writeFile(join(vault.lockDir, "pid"), String(process.ppid));
        return bunGitRunner(args, cwd, opts);
      },
    });
    expect(await readFile(join(vault.lockDir, "pid"), "utf8")).toBe(String(process.ppid));
  });
});

const isAlive = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/** Polls up to ~10 s: killed processes are reaped asynchronously, and a loaded host reaps late. */
async function waitUntilDead(pid: number): Promise<void> {
  for (let i = 0; i < 500 && isAlive(pid); i++) await Bun.sleep(20);
}

// The timeout starts at spawn, so on a loaded host it can fire before the fake git has even
// written its pid file. These budgets bound each attempt; a longer one is only used after a
// shorter one proved the script had not started yet.
const TIMEOUT_LADDER_MS = [1_000, 4_000, 16_000];

describe("git runner timeout", () => {
  let dir: string;
  const pids: number[] = [];

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "iris-journal-git-"));
  });

  afterEach(async () => {
    for (const pid of pids.splice(0)) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // already gone
      }
    }
    await rm(dir, { recursive: true, force: true });
  });

  /** A stand-in for `git` that starts `sleep` in the background (inheriting stdout and stderr), then runs `rest`. */
  async function fakeGit(rest: string, preamble = ""): Promise<{ bin: string; pidFile: string }> {
    const bin = join(dir, "fake-git.sh");
    const pidFile = join(dir, "child.pid");
    await writeFile(bin, `#!/bin/sh\n${preamble}\nsleep 30 &\necho $! > "${pidFile}"\n${rest}\n`, {
      mode: 0o755,
    });
    return { bin, pidFile };
  }

  /** The pid the fake git recorded; empty if it was stopped before it got that far. */
  async function recordedPid(pidFile: string): Promise<number | undefined> {
    const text = await readFile(pidFile, "utf8").catch(() => "");
    const pid = Number(text.trim());
    if (!Number.isInteger(pid) || pid <= 0) return undefined;
    pids.push(pid);
    return pid;
  }

  /**
   * Runs the hanging fake git until the timeout demonstrably fired on a script that had started,
   * i.e. there is a child to check. Never asserts on wall-clock time.
   */
  async function runHanging(
    rest: string,
    preamble = "",
  ): Promise<{ result: GitResult; childPid: number; timeoutMs: number }> {
    const { bin, pidFile } = await fakeGit(rest, preamble);
    const run = createGitRunner(bin);
    for (const timeoutMs of TIMEOUT_LADDER_MS) {
      await rm(pidFile, { force: true });
      const result = await run(["push"], dir, { timeoutMs });
      expect(result.code).toBe(124);
      const childPid = await recordedPid(pidFile);
      if (childPid !== undefined) return { result, childPid, timeoutMs };
    }
    throw new Error("the fake git never got to record its child within the longest timeout");
  }

  it("kills the whole process group when git hangs on a child holding the pipes", async () => {
    const { result, childPid, timeoutMs } = await runHanging("wait");

    expect(result.stderr).toContain(`git push timed out after ${timeoutMs}ms`);
    await waitUntilDead(childPid);
    expect(isAlive(childPid)).toBe(false);
  }, 60_000);

  it("escalates to SIGKILL when the group ignores SIGTERM", async () => {
    const { childPid } = await runHanging("wait", "trap '' TERM");

    await waitUntilDead(childPid);
    expect(isAlive(childPid)).toBe(false);
  }, 60_000);

  it("returns once git exits even though a child still holds stderr", async () => {
    // The child sleeps 30 s holding the pipes: awaiting their EOF would hit the test timeout.
    // Exit code 3 (not 124) shows the call returned on git's exit, not on its timeout.
    const { bin, pidFile } = await fakeGit("echo done; exit 3");
    const result = await createGitRunner(bin)(["status"], dir, { timeoutMs: 60_000 });

    expect(result).toMatchObject({ code: 3, stdout: "done\n" });
    await recordedPid(pidFile);
  }, 20_000);
});
