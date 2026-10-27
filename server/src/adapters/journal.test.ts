import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fixedClock } from "../ports/clock.js";
import {
  bunGitRunner,
  createJournalDestination,
  journalSlug,
  journalTitle,
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
