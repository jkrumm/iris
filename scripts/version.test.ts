import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { computeVersion, releaseNotes } from "./version";

let repo: string;
let baseline: string;

function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", repo, ...args], {
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

let counter = 0;
async function commit(subject: string, file: string) {
  await mkdir(join(repo, file, ".."), { recursive: true });
  await writeFile(join(repo, file), `${++counter}\n`);
  git("add", "-A");
  git("commit", "-q", "-m", subject);
}
const version = (head = "HEAD") => computeVersion({ repo, baseline, head });

beforeEach(async () => {
  repo = await mkdtemp(join(tmpdir(), "iris-version-"));
  git("init", "-q", "-b", "master");
  await commit("chore: start", "README.md");
  baseline = git("rev-parse", "HEAD");
});
afterEach(() => rm(repo, { recursive: true, force: true }));

describe("computeVersion", () => {
  it("is 0.1.0 at the baseline", () => {
    expect(version()).toBe("0.1.0");
  });

  it("grows the patch with each apple/ commit when there is no feat", async () => {
    await commit("fix(apple): a", "apple/a.swift");
    expect(version()).toBe("0.1.1");
    await commit("refactor(apple): b", "apple/b.swift");
    await commit("test(apple): c", "apple/Tests/c.swift");
    expect(version()).toBe("0.1.3");
  });

  it("a feat touching apple/ is minor + 1 and patch 0", async () => {
    await commit("fix(apple): a", "apple/a.swift");
    await commit("feat(ui): b", "apple/b.swift");
    expect(version()).toBe("0.2.0");
    await commit("fix(apple): c", "apple/c.swift");
    expect(version()).toBe("0.2.1");
    await commit("feat(apple)!: d", "apple/d.swift");
    expect(version()).toBe("0.3.0");
  });

  it("a feat that does not touch apple/ changes nothing", async () => {
    await commit("fix(apple): a", "apple/a.swift");
    await commit("feat(server): b", "server/b.ts");
    await commit("feat: c", "docs/c.md");
    expect(version()).toBe("0.1.1");
  });

  it("a non-apple commit and a lookalike subject are not feats", async () => {
    await commit("feature(apple): a", "apple/a.swift");
    await commit("fix(apple): feat in the middle", "apple/b.swift");
    await commit("chore: x", "scripts/x.sh");
    expect(version()).toBe("0.1.2");
  });

  it("is deterministic for a commit: an older head keeps its version", async () => {
    await commit("feat(apple): a", "apple/a.swift");
    const old = git("rev-parse", "HEAD");
    await commit("fix(apple): b", "apple/b.swift");
    expect(version()).toBe("0.2.1");
    expect(version(old)).toBe("0.2.0");
    expect(version(old)).toBe("0.2.0");
  });

  it("counts the commits of a merged PR branch, not the merge commit", async () => {
    await commit("fix(apple): a", "apple/a.swift");
    git("checkout", "-q", "-b", "pr");
    await commit("feat(apple): b", "apple/b.swift");
    await commit("fix(apple): c", "apple/c.swift");
    git("checkout", "-q", "master");
    git("merge", "-q", "--no-ff", "-m", "Merge pull request #1", "pr");
    expect(version()).toBe("0.2.1");
  });

  it("refuses a baseline the clone does not have", () => {
    expect(() => computeVersion({ repo, baseline: "0".repeat(40) })).toThrow(/not a commit/);
  });
});

describe("releaseNotes", () => {
  it("lists the apple/ subjects since the commit, newest first", async () => {
    await commit("feat(apple): old", "apple/a.swift");
    const since = git("rev-parse", "HEAD");
    await commit("fix(apple): one <b>", "apple/b.swift");
    await commit("feat(server): not the app", "server/s.ts");
    await commit("feat(ui): two", "apple/c.swift");
    expect(releaseNotes({ repo, since })).toBe("- feat(ui): two\n- fix(apple): one <b>\n");
    expect(releaseNotes({ repo, since, format: "html" })).toBe(
      "<ul><li>feat(ui): two</li><li>fix(apple): one &lt;b&gt;</li></ul>\n",
    );
  });

  it("is empty when nothing changed, and caps a long list", async () => {
    expect(releaseNotes({ repo, since: baseline })).toBe("");
    for (let i = 0; i < 43; i++) await commit(`fix(apple): n${i}`, `apple/n${i}.swift`);
    const lines = releaseNotes({ repo, since: baseline }).trim().split("\n");
    expect(lines).toHaveLength(41);
    expect(lines.at(-1)).toBe("- and 3 more");
  });
});
