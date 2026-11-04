import { describe, expect, it } from "bun:test";
import {
  advance,
  canRetryFrom,
  clipCodePoints,
  IllegalTransitionError,
  isResultReady,
  isTerminal,
  MEMO_STATES,
  nextStep,
  normalizeActions,
  normalizeKind,
  runsAct,
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
    ["act", "transcribed", "acted"],
    ["notify", "acted", "notified"],
  ];

  it.each(happy)("%s moves %s to %s", (step, from, to) => {
    expect(advance({ state: from, step, mode: "auto" })).toBe(to);
    expect(stateBefore({ step, mode: "auto" })).toBe(from);
  });

  it("throws on every step run from the wrong state", () => {
    for (const [step, from] of happy) {
      for (const state of MEMO_STATES.filter((s) => s !== from)) {
        expect(() => advance({ state, step, mode: "auto" })).toThrow(IllegalTransitionError);
      }
    }
  });

  it("has no route or summarize step in any pipeline", () => {
    for (const step of ["route", "summarize"] as const) {
      expect(() => advance({ state: "transcribed", step, mode: "auto" })).toThrow(
        IllegalTransitionError,
      );
      expect(() => stateBefore({ step, mode: "auto" })).toThrow(IllegalTransitionError);
    }
  });
});

describe("helpers", () => {
  it("nextStep names the handler step, never ingest, and stops at old and final states", () => {
    expect(nextStep({ state: "receiving", mode: "auto" })).toBeNull();
    expect(nextStep({ state: "received", mode: "auto" })).toBe("transcribe");
    expect(nextStep({ state: "transcribed", mode: "auto" })).toBe("act");
    expect(nextStep({ state: "acted", mode: "auto" })).toBe("notify");
    for (const state of ["routed", "summarized", "needs_route", "notified", "failed"] as const) {
      expect(nextStep({ state, mode: "auto" })).toBeNull();
    }
  });

  it("separates terminal from result-ready", () => {
    expect(MEMO_STATES.filter(isTerminal)).toEqual(["notified", "failed"]);
    expect(MEMO_STATES.filter(isResultReady)).toEqual(["needs_route", "notified", "failed"]);
  });

  it("stepsFrom lists the step and everything after it in the full timeline", () => {
    expect(stepsFrom("act")).toEqual(["act", "summarize", "notify"]);
    expect(stepsFrom("transcribe")).toEqual(["transcribe", "route", "act", "summarize", "notify"]);
  });
});

describe("runsAct", () => {
  it("is every mode but transcribe", () => {
    for (const mode of ["auto", "journal", "hermes", "tab", "chat"] as const) {
      expect(runsAct(mode)).toBe(true);
    }
    expect(runsAct("transcribe")).toBe(false);
  });
});

describe("stepsOf", () => {
  it("is ingest, transcribe, act, notify for every mode that runs act", () => {
    for (const mode of ["auto", "journal", "hermes", "tab", "chat"] as const) {
      expect(stepsOf(mode)).toEqual(["ingest", "transcribe", "act", "notify"]);
    }
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

  it("refuses the steps it does not have, and notify from acted", () => {
    for (const step of ["route", "act", "summarize"] as const) {
      expect(() => advance({ state: "transcribed", step, mode: "transcribe" })).toThrow(
        IllegalTransitionError,
      );
    }
    expect(() => advance({ state: "acted", step: "notify", mode: "transcribe" })).toThrow(
      IllegalTransitionError,
    );
    expect(() => stateBefore({ step: "act", mode: "transcribe" })).toThrow(IllegalTransitionError);
  });
});

describe("canRetryFrom", () => {
  it("allows any pipeline step up to the failed one", () => {
    expect(canRetryFrom({ from: "transcribe", failedStep: "act", mode: "auto" })).toBe(true);
    expect(canRetryFrom({ from: "act", failedStep: "act", mode: "auto" })).toBe(true);
    expect(canRetryFrom({ from: "notify", failedStep: "act", mode: "auto" })).toBe(false);
    expect(canRetryFrom({ from: "act", failedStep: "transcribe", mode: "auto" })).toBe(false);
  });

  it("treats an old failed(route) as failed at act", () => {
    expect(canRetryFrom({ from: "transcribe", failedStep: "route", mode: "auto" })).toBe(true);
    expect(canRetryFrom({ from: "act", failedStep: "route", mode: "auto" })).toBe(true);
    expect(canRetryFrom({ from: "notify", failedStep: "route", mode: "auto" })).toBe(false);
  });

  it("treats an old failed(summarize) as failed at notify", () => {
    expect(canRetryFrom({ from: "act", failedStep: "summarize", mode: "auto" })).toBe(true);
    expect(canRetryFrom({ from: "notify", failedStep: "summarize", mode: "auto" })).toBe(true);
  });

  it("refuses a step outside the pipeline", () => {
    expect(canRetryFrom({ from: "act", failedStep: "transcribe", mode: "transcribe" })).toBe(false);
    expect(canRetryFrom({ from: "notify", failedStep: "notify", mode: "transcribe" })).toBe(true);
  });
});

describe("normalizeKind", () => {
  it("trims and lower-cases", () => {
    expect(normalizeKind("  Shopping ")).toBe("shopping");
  });

  it("turns blank into null", () => {
    expect(normalizeKind("")).toBeNull();
    expect(normalizeKind("   ")).toBeNull();
  });

  it("cuts to 24 code points without splitting a surrogate pair", () => {
    expect(normalizeKind("a".repeat(40))).toBe("a".repeat(24));
    const emoji = "😀".repeat(30);
    expect(normalizeKind(emoji)).toBe("😀".repeat(24));
  });
});

describe("normalizeActions", () => {
  it("dedupes in first-seen order, trims and drops blanks", () => {
    expect(normalizeActions([" search ", "write", "search", "", "  ", "write", "read"])).toEqual([
      "search",
      "write",
      "read",
    ]);
  });

  it("keeps at most 12", () => {
    const names = Array.from({ length: 20 }, (_, i) => `tool_${i}`);
    expect(normalizeActions(names)).toEqual(names.slice(0, 12));
  });
});

describe("clipCodePoints", () => {
  it("returns short text unchanged", () => {
    expect(clipCodePoints("hello", 5)).toBe("hello");
  });

  it("cuts with an ellipsis, trimming the trailing space first", () => {
    expect(clipCodePoints("hello world", 7)).toBe("hello…");
    expect(clipCodePoints("abcdefghij", 5)).toBe("abcd…");
  });

  it("counts code points, not UTF-16 units", () => {
    expect(clipCodePoints("😀".repeat(10), 10)).toBe("😀".repeat(10));
    expect(clipCodePoints("😀".repeat(11), 10)).toBe(`${"😀".repeat(9)}…`);
  });
});
