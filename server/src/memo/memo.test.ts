import { describe, expect, it } from "bun:test";
import {
  advance,
  IllegalTransitionError,
  isResultReady,
  isTerminal,
  MEMO_STATES,
  nextStep,
  stateBefore,
  stepsFrom,
  type MemoState,
  type Step,
} from "./memo.js";

describe("transition table", () => {
  const happy: [Step, MemoState, MemoState][] = [
    ["ingest", "receiving", "received"],
    ["transcribe", "received", "transcribed"],
    ["route", "transcribed", "routed"],
    ["act", "routed", "acted"],
    ["summarize", "acted", "summarized"],
    ["notify", "summarized", "notified"],
  ];

  it.each(happy)("%s moves %s to %s", (step, from, to) => {
    expect(advance({ state: from, step })).toBe(to);
    expect(stateBefore(step)).toBe(from);
  });

  it("lets route and act park in needs_route, no other step", () => {
    expect(advance({ state: "transcribed", step: "route", outcome: "needs_route" })).toBe(
      "needs_route",
    );
    expect(advance({ state: "routed", step: "act", outcome: "needs_route" })).toBe("needs_route");
    expect(() => advance({ state: "acted", step: "summarize", outcome: "needs_route" })).toThrow(
      IllegalTransitionError,
    );
    expect(() => advance({ state: "summarized", step: "notify", outcome: "needs_route" })).toThrow(
      IllegalTransitionError,
    );
  });

  it("throws on every step run from the wrong state", () => {
    for (const [step, from] of happy) {
      for (const state of MEMO_STATES.filter((s) => s !== from)) {
        expect(() => advance({ state, step })).toThrow(IllegalTransitionError);
      }
    }
  });
});

describe("helpers", () => {
  it("nextStep names the handler step, never ingest, and stops at parked and final states", () => {
    expect(nextStep("receiving")).toBeNull();
    expect(nextStep("received")).toBe("transcribe");
    expect(nextStep("transcribed")).toBe("route");
    expect(nextStep("routed")).toBe("act");
    expect(nextStep("acted")).toBe("summarize");
    expect(nextStep("summarized")).toBe("notify");
    for (const state of ["needs_route", "notified", "failed"] as const) {
      expect(nextStep(state)).toBeNull();
    }
  });

  it("separates terminal from result-ready", () => {
    expect(MEMO_STATES.filter(isTerminal)).toEqual(["notified", "failed"]);
    expect(MEMO_STATES.filter(isResultReady)).toEqual(["needs_route", "notified", "failed"]);
  });

  it("stepsFrom lists the step and everything after it", () => {
    expect(stepsFrom("act")).toEqual(["act", "summarize", "notify"]);
  });
});
