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
  stepsOf,
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
    expect(advance({ state: from, step, mode: "auto" })).toBe(to);
    expect(stateBefore({ step, mode: "auto" })).toBe(from);
  });

  it("lets route and act park in needs_route, no other step", () => {
    expect(
      advance({ state: "transcribed", step: "route", mode: "auto", outcome: "needs_route" }),
    ).toBe("needs_route");
    expect(advance({ state: "routed", step: "act", mode: "auto", outcome: "needs_route" })).toBe(
      "needs_route",
    );
    expect(() =>
      advance({ state: "acted", step: "summarize", mode: "auto", outcome: "needs_route" }),
    ).toThrow(IllegalTransitionError);
    expect(() =>
      advance({ state: "summarized", step: "notify", mode: "auto", outcome: "needs_route" }),
    ).toThrow(IllegalTransitionError);
  });

  it("throws on every step run from the wrong state", () => {
    for (const [step, from] of happy) {
      for (const state of MEMO_STATES.filter((s) => s !== from)) {
        expect(() => advance({ state, step, mode: "auto" })).toThrow(IllegalTransitionError);
      }
    }
  });
});

describe("helpers", () => {
  it("nextStep names the handler step, never ingest, and stops at parked and final states", () => {
    expect(nextStep({ state: "receiving", mode: "auto" })).toBeNull();
    expect(nextStep({ state: "received", mode: "auto" })).toBe("transcribe");
    expect(nextStep({ state: "transcribed", mode: "auto" })).toBe("route");
    expect(nextStep({ state: "routed", mode: "auto" })).toBe("act");
    expect(nextStep({ state: "acted", mode: "auto" })).toBe("summarize");
    expect(nextStep({ state: "summarized", mode: "auto" })).toBe("notify");
    for (const state of ["needs_route", "notified", "failed"] as const) {
      expect(nextStep({ state, mode: "auto" })).toBeNull();
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

describe("mode transcribe", () => {
  it("runs transcribe, then notify straight from transcribed", () => {
    expect(stepsOf("transcribe")).toEqual(["ingest", "transcribe", "notify"]);
    expect(nextStep({ state: "received", mode: "transcribe" })).toBe("transcribe");
    expect(nextStep({ state: "transcribed", mode: "transcribe" })).toBe("notify");
    expect(nextStep({ state: "notified", mode: "transcribe" })).toBeNull();
    expect(advance({ state: "transcribed", step: "notify", mode: "transcribe" })).toBe("notified");
    expect(stateBefore({ step: "notify", mode: "transcribe" })).toBe("transcribed");
  });

  it("refuses the steps it does not have, and notify from summarized", () => {
    for (const step of ["route", "act", "summarize"] as const) {
      expect(() => advance({ state: "transcribed", step, mode: "transcribe" })).toThrow(
        IllegalTransitionError,
      );
    }
    expect(() => advance({ state: "summarized", step: "notify", mode: "transcribe" })).toThrow(
      IllegalTransitionError,
    );
  });

  it("leaves every other mode's pipeline whole", () => {
    expect(stepsOf("auto")).toEqual([
      "ingest",
      "transcribe",
      "route",
      "act",
      "summarize",
      "notify",
    ]);
  });
});
