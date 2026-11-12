#!/usr/bin/env bun
/**
 * The merge guard (`make merge-guard`): what a lead runs just before it merges its pull request, so parallel leads
 * never land onto a master that moved or is red. It refuses, with the reason, when
 *   - origin/master is unknown,
 *   - the branch does not contain the current `origin/master` (rebase, then `make check` again),
 *   - master's last `check.yml` run is red or still running (`--allow-red` is for the one change that fixes a red master),
 *   - the head has no finished green `check.yml` run (the full gate runs in CI, `project.yaml` `checks.ci`), or touches a path
 *     `apple.yml` is filtered on (read from the workflow itself) and has no finished green `apple.yml` run.
 * `--wait` polls while the head's runs are still running (up to 45 min); without it a running run is a refusal.
 * `--no-fetch` skips the `git fetch`. Exit 0 when clear, 1 on a refusal (the reasons on stderr), 2 on a usage error.
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

export interface CiRun {
  status: string;
  conclusion: string;
  url: string;
}

export interface GuardPorts {
  /** `git <args>` in the repo; the trimmed stdout, or null when git exits non-zero */
  git(args: string[]): string | null;
  /** master's `check.yml` runs, newest first; null when they cannot be read */
  ciRuns(): CiRun[] | null;
  /** the runs of a workflow file on the head commit, newest first; null when they cannot be read */
  headRuns(workflow: string): CiRun[] | null;
  /** the files the branch changes against origin/master; null when git cannot say */
  changedFiles(): string[] | null;
  /** the `pull_request` path filter of `.github/workflows/apple.yml`; null when it cannot be read */
  applePaths(): string[] | null;
}

export interface Verdict {
  /** final: waiting does not help */
  refusals: string[];
  /** a run of the head is still going or not yet visible: `--wait` polls these */
  pending: string[];
}

/** Does `path` match one of the workflow's path globs? */
export function matchesPaths(globs: string[], files: string[]): boolean {
  const compiled = globs.map((glob) => new Bun.Glob(glob));
  return files.some((file) => compiled.some((glob) => glob.match(file)));
}

export type HeadState = { kind: "green" } | { kind: "pending" | "red" | "none"; reason: string };

/** The head's run of one workflow: cancelled runs were superseded and are skipped. */
export function headState(workflow: string, runs: CiRun[] | null): HeadState {
  if (runs === null)
    return { kind: "red", reason: `${workflow} runs of the head cannot be read (gh failed)` };
  const last = runs.find((r) => r.conclusion !== "cancelled");
  if (!last) return { kind: "none", reason: `${workflow} has no finished run on the head` };
  if (last.status !== "completed")
    return { kind: "pending", reason: `${workflow} is still running on the head (${last.url})` };
  if (last.conclusion !== "success")
    return {
      kind: "red",
      reason: `${workflow} is ${last.conclusion} on the head (${last.url}): fix it, never merge around it`,
    };
  return { kind: "green" };
}

/** master's last CI run: cancelled runs were superseded by a newer one and are skipped. A refusal reason, or null when green. */
export function masterRed(runs: CiRun[] | null): string | null {
  if (runs === null)
    return "master's CI runs cannot be read (gh failed): refusing, a merge needs to know master is green";
  const last = runs.find((run) => run.conclusion !== "cancelled");
  if (!last) return "master has no finished CI run: wait for the first one before merging";
  if (last.status !== "completed")
    return `master's CI run is still running (${last.url}): merge once it is green`;
  if (last.conclusion !== "success")
    return `master's last CI run is ${last.conclusion} (${last.url}): fix master first, a merge onto red hides the next break (--allow-red only for the change that fixes it)`;
  return null;
}

export function evaluate(ports: GuardPorts, options: { allowRed?: boolean } = {}): Verdict {
  const refusals: string[] = [];
  const pending: string[] = [];

  if (ports.git(["rev-parse", "--verify", "-q", "origin/master"]) === null) {
    refusals.push("origin/master is unknown: git fetch origin master");
    return { refusals, pending };
  }
  if (ports.git(["merge-base", "--is-ancestor", "origin/master", "HEAD"]) === null) {
    refusals.push(
      "master moved: this branch does not contain origin/master. git fetch origin master && git rebase origin/master, then make check again",
    );
  }

  if (!options.allowRed) {
    const red = masterRed(ports.ciRuns());
    if (red) refusals.push(red);
  }

  // The full gate is CI's (project.yaml `checks.ci`): the exact head needs its own finished green run, apple.yml too when its filter matches.
  const required = [["check.yml", true]] as [string, boolean][];
  const files = ports.changedFiles();
  const globs = ports.applePaths();
  if (files === null || globs === null) {
    refusals.push(
      "cannot tell whether apple.yml applies (changed files or its path filter unreadable)",
    );
  } else {
    required.push(["apple.yml", matchesPaths(globs, files)]);
  }
  for (const [workflow, needed] of required) {
    if (!needed) continue;
    const state = headState(workflow, ports.headRuns(workflow));
    if (state.kind === "pending" || state.kind === "none") pending.push(state.reason);
    else if (state.kind === "red") refusals.push(state.reason);
  }
  return { refusals, pending };
}

const APPLE_WORKFLOW = ".github/workflows/apple.yml";

function realPorts(): GuardPorts {
  const gh = (args: string[]): CiRun[] | null => {
    const out = spawnSync("gh", args, { encoding: "utf8" });
    if (out.status !== 0) return null;
    try {
      return JSON.parse(out.stdout) as CiRun[];
    } catch {
      return null;
    }
  };
  return {
    git(args) {
      const out = spawnSync("git", args, { encoding: "utf8" });
      return out.status === 0 ? out.stdout.trim() : null;
    },
    ciRuns() {
      return gh([
        "run",
        "list",
        "--branch",
        "master",
        "--workflow",
        "check.yml",
        "--limit",
        "10",
        "--json",
        "status,conclusion,url",
      ]);
    },
    headRuns(workflow) {
      const sha = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim();
      return gh([
        "run",
        "list",
        "--commit",
        sha,
        "--workflow",
        workflow,
        "--limit",
        "10",
        "--json",
        "status,conclusion,url",
      ]);
    },
    changedFiles() {
      const out = spawnSync("git", ["diff", "--name-only", "origin/master...HEAD"], {
        encoding: "utf8",
      });
      return out.status === 0 ? out.stdout.split("\n").filter(Boolean) : null;
    },
    applePaths() {
      try {
        const doc = Bun.YAML.parse(readFileSync(APPLE_WORKFLOW, "utf8")) as {
          on?: { pull_request?: { paths?: string[] } };
        };
        return doc.on?.pull_request?.paths ?? null;
      } catch {
        return null;
      }
    },
  };
}

const WAIT_LIMIT_MS = 45 * 60_000;
const POLL_MS = 30_000;

if (import.meta.main) {
  const args = process.argv.slice(2);
  const unknown = args.filter((a) => !["--allow-red", "--no-fetch", "--wait"].includes(a));
  if (unknown.length > 0) {
    console.error(`merge-guard: unknown argument ${unknown[0]}`);
    process.exit(2);
  }
  const ports = realPorts();
  if (!args.includes("--no-fetch")) ports.git(["fetch", "--quiet", "origin", "master"]);
  const evaluateNow = () => evaluate(ports, { allowRed: args.includes("--allow-red") });
  let verdict = evaluateNow();
  const deadline = Date.now() + WAIT_LIMIT_MS;
  while (
    args.includes("--wait") &&
    verdict.refusals.length === 0 &&
    verdict.pending.length > 0 &&
    Date.now() < deadline
  ) {
    console.error(`merge-guard: waiting: ${verdict.pending.join("; ")}`);
    Bun.sleepSync(POLL_MS);
    verdict = evaluateNow();
  }
  const reasons = [...verdict.refusals, ...verdict.pending];
  if (reasons.length > 0) {
    for (const reason of reasons) console.error(`merge-guard: refused: ${reason}`);
    process.exit(1);
  }
  console.log("merge-guard: clear (rebased on origin/master, master and the head green)");
}
