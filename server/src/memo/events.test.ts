import { describe, expect, it } from "bun:test";
import { createMemoEvents, type MemoEvent } from "./events.js";

const event: MemoEvent = {
  id: "m1",
  state: "received",
  step: "ingest",
  failedStep: null,
  error: null,
  at: "2026-01-01T00:00:00.000Z",
};

describe("MemoEvents", () => {
  it("delivers to every subscriber until it unsubscribes", () => {
    const events = createMemoEvents();
    const a: MemoEvent[] = [];
    const b: MemoEvent[] = [];
    const offA = events.subscribe((e) => a.push(e));
    events.subscribe((e) => b.push(e));
    events.publish(event);
    offA();
    events.publish(event);
    expect(a).toHaveLength(1);
    expect(b).toHaveLength(2);
  });

  it("isolates a throwing listener from the publisher and its peers", () => {
    const events = createMemoEvents();
    const seen: MemoEvent[] = [];
    events.subscribe(() => {
      throw new Error("boom");
    });
    events.subscribe((e) => seen.push(e));
    expect(() => events.publish(event)).not.toThrow();
    expect(seen).toEqual([event]);
  });

  it("tolerates a listener that unsubscribes itself mid-publish", () => {
    const events = createMemoEvents();
    const seen: string[] = [];
    const off = events.subscribe(() => {
      seen.push("first");
      off();
    });
    events.subscribe(() => seen.push("second"));
    events.publish(event);
    events.publish(event);
    expect(seen).toEqual(["first", "second", "second"]);
  });
});
