// The marketing version of both Apple apps, computed from git: 0.MINOR.PATCH, deterministic for a commit (no tag, no stored state).
//
//   bun scripts/version.ts [--head <rev>] [--baseline <rev>] [--repo <dir>]     prints e.g. 0.4.2
//   bun scripts/version.ts notes [--since <rev>] [--format md|html] [...]       the release notes: subjects of the apple/ commits since <rev>
//
// The commits that count are the non-merge commits reachable from the head and not from the baseline that touch `apple/`
// (`--full-history`, so a PR's own commits count whatever the merge method). In topological order, newest first:
//   MINOR = 1 + the number of those whose subject is `feat` (any scope, `!` allowed)
//   PATCH = the number of those newer than the newest `feat` (all of them while there is none)
// The baseline is the commit of the last 0.1.0 Mac release, so the first computed version is above 0.1.0. A feat that does not touch
// `apple/` changes nothing: a server change must not look like a new app version.
import { spawnSync } from "node:child_process";

/** mac-v0.1.0-799 (2026-11-12): the last release that shipped 0.1.0. */
export const BASELINE = "280378d66b60e94f2ea9a9fa27fdfc824b23d142";

const FEAT = /^feat(\([^)]*\))?!?:/;
const NOTES_MAX = 40;

export type Commit = { sha: string; subject: string };
export type Range = { repo: string; since: string; head?: string | undefined };

function git(repo: string, args: string[]): string {
  const r = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.trim()}`);
  return r.stdout;
}

/** The apple/ commits in (since, head], newest first. */
export function appleCommits({ repo, since, head = "HEAD" }: Range): Commit[] {
  for (const rev of [since, head]) {
    const r = spawnSync("git", ["-C", repo, "cat-file", "-e", `${rev}^{commit}`]);
    if (r.status !== 0)
      throw new Error(
        `${rev} is not a commit of this clone (a shallow clone cannot compute the version)`,
      );
  }
  const out = git(repo, [
    "log",
    "--full-history",
    "--no-merges",
    "--topo-order",
    "--format=%H%x09%s",
    head,
    `^${since}`,
    "--",
    "apple",
  ]);
  return out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const tab = line.indexOf("\t");
      return { sha: line.slice(0, tab), subject: line.slice(tab + 1) };
    });
}

export function computeVersion({
  repo,
  baseline = BASELINE,
  head,
}: {
  repo: string;
  baseline?: string | undefined;
  head?: string | undefined;
}): string {
  const commits = appleCommits({ repo, since: baseline, head });
  const feats = commits.filter((c) => FEAT.test(c.subject)).length;
  const firstFeat = commits.findIndex((c) => FEAT.test(c.subject));
  const patch = firstFeat === -1 ? commits.length : firstFeat;
  return `0.${1 + feats}.${patch}`;
}

const escapeHtml = (s: string) =>
  s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

/** Release notes: the subjects since `since`, newest first, capped; "" when nothing changed. */
export function releaseNotes({
  format = "md",
  ...range
}: Range & { format?: "md" | "html" }): string {
  const commits = appleCommits(range);
  if (commits.length === 0) return "";
  const shown = commits.slice(0, NOTES_MAX).map((c) => c.subject);
  const more = commits.length - shown.length;
  if (format === "md") {
    return (
      [...shown.map((s) => `- ${s}`), ...(more > 0 ? [`- and ${more} more`] : [])].join("\n") + "\n"
    );
  }
  const items = [...shown.map(escapeHtml), ...(more > 0 ? [`and ${more} more`] : [])];
  return `<ul>${items.map((s) => `<li>${s}</li>`).join("")}</ul>\n`;
}

function main(argv: string[]) {
  const notes = argv[0] === "notes";
  const args = notes ? argv.slice(1) : argv;
  const opt = (name: string) => {
    const i = args.indexOf(`--${name}`);
    return i === -1 ? undefined : args[i + 1];
  };
  const repo = opt("repo") ?? process.cwd();
  const head = opt("head") ?? "HEAD";
  if (!notes) {
    console.log(computeVersion({ repo, baseline: opt("baseline") ?? BASELINE, head }));
    return;
  }
  const format = opt("format") ?? "md";
  if (format !== "md" && format !== "html")
    throw new Error(`--format must be md or html, not ${format}`);
  process.stdout.write(releaseNotes({ repo, since: opt("since") ?? BASELINE, format, head }));
}

if (import.meta.main) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`  version: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}
