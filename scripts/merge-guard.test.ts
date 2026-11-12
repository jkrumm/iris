import { describe, expect, it } from "bun:test";
import {
  type CiRun,
  type GuardPorts,
  evaluate,
  headState,
  masterRed,
  matchesPaths,
} from "./merge-guard";

const APPLE_PATHS = ["apple/**", "contracts/**", "Makefile", "scripts/uitest-*"];

const run = (status: string, conclusion: string): CiRun => ({
  status,
  conclusion,
  url: "https://example.com/run/1",
});
const green = run("completed", "success");

const ports = (options: {
  known?: boolean;
  rebased?: boolean;
  runs?: CiRun[] | null;
  /** the head's check.yml runs (default green) */
  headCheck?: CiRun[] | null;
  /** the head's apple.yml runs (default none) */
  headApple?: CiRun[] | null;
  files?: string[] | null;
  paths?: string[] | null;
}): GuardPorts => ({
  git(args) {
    if (args[0] === "rev-parse") return options.known === false ? null : "abc123";
    if (args[0] === "merge-base") return options.rebased === false ? null : "";
    return "";
  },
  ciRuns: () => (options.runs === undefined ? [green] : options.runs),
  headRuns: (workflow) =>
    workflow === "check.yml"
      ? options.headCheck === undefined
        ? [green]
        : options.headCheck
      : options.headApple === undefined
        ? []
        : options.headApple,
  changedFiles: () => (options.files === undefined ? ["server/src/app.ts"] : options.files),
  applePaths: () => (options.paths === undefined ? APPLE_PATHS : options.paths),
});

describe("masterRed", () => {
  it("refuses when the runs cannot be read", () => {
    expect(masterRed(null)).toContain("cannot be read");
  });

  it("refuses when every run is cancelled", () => {
    expect(masterRed([run("completed", "cancelled")])).toContain("no finished CI run");
  });

  it("refuses while the last run is still running", () => {
    expect(masterRed([run("in_progress", "")])).toContain("still running");
  });

  it("refuses a failed last run", () => {
    expect(masterRed([run("completed", "failure")])).toContain("failure");
  });

  it("is clear for a success behind a cancelled newer run", () => {
    expect(masterRed([run("completed", "cancelled"), green])).toBeNull();
  });
});

describe("evaluate", () => {
  it("refuses when origin/master is unknown", () => {
    expect(evaluate(ports({ known: false })).refusals).toEqual([
      "origin/master is unknown: git fetch origin master",
    ]);
  });

  it("refuses a branch that does not contain origin/master", () => {
    const { refusals } = evaluate(ports({ rebased: false }));
    expect(refusals).toHaveLength(1);
    expect(refusals[0]).toContain("git rebase origin/master");
  });

  it("skips the CI check with allowRed", () => {
    expect(
      evaluate(ports({ runs: [run("completed", "failure")] }), { allowRed: true }).refusals,
    ).toEqual([]);
  });

  it("still refuses a red master without allowRed", () => {
    expect(evaluate(ports({ runs: [run("completed", "failure")] })).refusals).toHaveLength(1);
  });

  it("is clear when rebased on a green master", () => {
    expect(evaluate(ports({})).refusals).toEqual([]);
  });
});

describe("matchesPaths", () => {
  it("matches the workflow's globs", () => {
    expect(matchesPaths(APPLE_PATHS, ["apple/Packages/IrisCore/Foo.swift"])).toBe(true);
    expect(matchesPaths(APPLE_PATHS, ["scripts/uitest-map.json"])).toBe(true);
    expect(matchesPaths(APPLE_PATHS, ["server/src/app.ts", "docs/TDD.md"])).toBe(false);
  });
});

describe("headState", () => {
  it("is pending while the run goes and none before one exists", () => {
    expect(headState("check.yml", [run("in_progress", "")]).kind).toBe("pending");
    expect(headState("check.yml", []).kind).toBe("none");
  });

  it("is red on a failure or an unreadable list", () => {
    expect(headState("check.yml", [run("completed", "failure")]).kind).toBe("red");
    expect(headState("check.yml", null).kind).toBe("red");
  });

  it("skips a cancelled newer run", () => {
    expect(headState("check.yml", [run("completed", "cancelled"), green]).kind).toBe("green");
  });
});

describe("evaluate: the head's CI", () => {
  it("is pending (not final) while check.yml runs on the head", () => {
    const verdict = evaluate(ports({ headCheck: [run("in_progress", "")] }));
    expect(verdict.refusals).toEqual([]);
    expect(verdict.pending).toHaveLength(1);
  });

  it("refuses a red head even with allowRed", () => {
    const verdict = evaluate(ports({ headCheck: [run("completed", "failure")] }), {
      allowRed: true,
    });
    expect(verdict.refusals).toHaveLength(1);
  });

  it("waits for a head with no run yet", () => {
    expect(evaluate(ports({ headCheck: [] })).pending).toHaveLength(1);
  });

  it("does not need apple.yml when no changed file matches its filter", () => {
    expect(evaluate(ports({ files: ["server/src/app.ts"], headApple: [] }))).toEqual({
      refusals: [],
      pending: [],
    });
  });

  it("needs a green apple.yml run when apple/** changed", () => {
    const files = ["apple/Packages/IrisCore/Foo.swift"];
    expect(evaluate(ports({ files, headApple: [] })).pending).toHaveLength(1);
    expect(
      evaluate(ports({ files, headApple: [run("completed", "failure")] })).refusals,
    ).toHaveLength(1);
    expect(evaluate(ports({ files, headApple: [green] }))).toEqual({ refusals: [], pending: [] });
  });

  it("refuses when it cannot tell whether apple.yml applies", () => {
    expect(evaluate(ports({ files: null })).refusals).toHaveLength(1);
    expect(evaluate(ports({ paths: null })).refusals).toHaveLength(1);
  });
});
