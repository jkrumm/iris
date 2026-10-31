import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import { TabGoneError, type Destination } from "../ports/destination.js";
import { fakeHerd } from "../ports/fakes.js";
import type { HerdTab } from "../ports/herd.js";
import { mergeHerds, preferHc } from "./herdr-worlds.js";

const tab = (id: string): HerdTab => ({
  id,
  repo: "iris",
  label: id,
  agentState: "idle",
  lastActivity: null,
});
const down = new MemoError("unavailable", "down");

describe("mergeHerds", () => {
  it("lists every world, in order", async () => {
    const herd = mergeHerds([fakeHerd({ tabs: [tab("tbA")] }), fakeHerd({ tabs: [tab("w2:t1")] })]);
    expect((await herd.snapshot()).map((t) => t.id)).toEqual(["tbA", "w2:t1"]);
  });

  it("fails when any world fails, so routing never picks from a partial list", async () => {
    const herd = mergeHerds([fakeHerd({ failWith: down }), fakeHerd({ tabs: [tab("w2:t1")] })]);
    await expect(herd.snapshot()).rejects.toBe(down);
  });
});

function destination(outcome: "ok" | Error) {
  const tabs: (string | undefined)[] = [];
  const d: Destination & { tabs: typeof tabs } = {
    tabs,
    async deliver({ tab }) {
      tabs.push(tab);
      if (outcome !== "ok") throw outcome;
      return { ref: `${tab}`, replyText: "" };
    },
  };
  return d;
}
const params = { memoId: "m", transcript: "hi", tab: "tbA" };

describe("preferHc", () => {
  it("delivers through hc and never touches classic when hc has the tab", async () => {
    const hc = destination("ok");
    const classic = destination("ok");
    await preferHc({ hc, classic }).deliver(params);
    expect([hc.tabs, classic.tabs]).toEqual([["tbA"], []]);
  });

  it("falls back to classic when hc does not know the tab", async () => {
    const classic = destination("ok");
    const result = await preferHc({ hc: destination(new TabGoneError("tbA")), classic }).deliver({
      ...params,
      tab: "w2:t1",
    });
    expect(result.ref).toBe("w2:t1");
  });

  it("falls back to classic when hc is unreachable", async () => {
    const classic = destination("ok");
    await preferHc({ hc: destination(down), classic }).deliver(params);
    expect(classic.tabs).toEqual(["tbA"]);
  });

  it("keeps hc's own error when classic does not know the tab either", async () => {
    const hcError = new MemoError("unavailable", "terminal t3 queue is full");
    await expect(
      preferHc({ hc: destination(hcError), classic: destination(new TabGoneError("tbA")) }).deliver(
        params,
      ),
    ).rejects.toBe(hcError);
    const gone = new TabGoneError("tbA");
    await expect(
      preferHc({ hc: destination(gone), classic: destination(new TabGoneError("tbA")) }).deliver(
        params,
      ),
    ).rejects.toBe(gone);
  });

  it("surfaces classic's failure when classic knows the tab but cannot deliver", async () => {
    const boom = new MemoError("unavailable", "pane queue is full");
    await expect(
      preferHc({ hc: destination(new TabGoneError("w2:t1")), classic: destination(boom) }).deliver(
        params,
      ),
    ).rejects.toBe(boom);
  });
});
