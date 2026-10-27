import { describe, expect, it } from "bun:test";
import { fixedClock, manualClock } from "./clock.js";

describe("clocks", () => {
  it("fixedClock never moves", () => {
    const clock = fixedClock("2026-03-04T05:06:07.000Z");
    expect(clock.now().toISOString()).toBe("2026-03-04T05:06:07.000Z");
    expect(clock.now().toISOString()).toBe("2026-03-04T05:06:07.000Z");
  });

  it("manualClock moves only on advance", () => {
    const clock = manualClock("2026-01-01T00:00:00.000Z");
    clock.advance(1500);
    expect(clock.now().toISOString()).toBe("2026-01-01T00:00:01.500Z");
  });
});
