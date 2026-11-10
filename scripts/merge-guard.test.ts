import { describe, expect, it } from "bun:test";
import { type CiRun, type GuardPorts, evaluate, masterRed } from "./merge-guard";

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
}): GuardPorts => ({
  git(args) {
    if (args[0] === "rev-parse") return options.known === false ? null : "abc123";
    if (args[0] === "merge-base") return options.rebased === false ? null : "";
    return "";
  },
  ciRuns: () => (options.runs === undefined ? [green] : options.runs),
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
