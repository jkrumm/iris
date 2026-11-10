#!/usr/bin/env bun
/**
 * The merge guard (`make merge-guard`): what a lead runs just before it merges its pull request, so parallel leads
 * never land onto a master that moved or is red. It refuses, with the reason, when
 *   - origin/master is unknown,
 *   - the branch does not contain the current `origin/master` (rebase, then `make check` again),
 *   - master's last `check.yml` run is red or still running (`--allow-red` is for the one change that fixes a red master).
 * `apple.yml` is a separate workflow and not part of the gate. `--no-fetch` skips the `git fetch`.
 * Exit 0 when clear, 1 on a refusal (the reasons on stderr), 2 on a usage error.
 */
import { spawnSync } from "node:child_process";

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
}

export interface Verdict {
  refusals: string[];
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

  if (ports.git(["rev-parse", "--verify", "-q", "origin/master"]) === null) {
    refusals.push("origin/master is unknown: git fetch origin master");
    return { refusals };
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
  return { refusals };
}

function realPorts(): GuardPorts {
  return {
    git(args) {
      const out = spawnSync("git", args, { encoding: "utf8" });
      return out.status === 0 ? out.stdout.trim() : null;
    },
    ciRuns() {
      const out = spawnSync(
        "gh",
        [
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
        ],
        { encoding: "utf8" },
      );
      if (out.status !== 0) return null;
      try {
        return JSON.parse(out.stdout) as CiRun[];
      } catch {
        return null;
      }
    },
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const unknown = args.filter((a) => !["--allow-red", "--no-fetch"].includes(a));
  if (unknown.length > 0) {
    console.error(`merge-guard: unknown argument ${unknown[0]}`);
    process.exit(2);
  }
  const ports = realPorts();
  if (!args.includes("--no-fetch")) ports.git(["fetch", "--quiet", "origin", "master"]);
  const verdict = evaluate(ports, { allowRed: args.includes("--allow-red") });
  if (verdict.refusals.length > 0) {
    for (const reason of verdict.refusals) console.error(`merge-guard: refused: ${reason}`);
    process.exit(1);
  }
  console.log("merge-guard: clear (rebased on origin/master, master green)");
}
