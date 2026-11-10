import { describe, expect, it } from "bun:test";
import { createReplyProgress, visiblePrefix, type ProgressEvent } from "./progress.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe("visiblePrefix", () => {
  it("drops leading whitespace and holds back trailing whitespace", () => {
    expect(visiblePrefix("\n\nHello ")).toBe("Hello");
    expect(visiblePrefix("\n\n")).toBe("");
  });

  it("cuts at the iris fence and never shows what follows", () => {
    expect(visiblePrefix('Done.\n\n```iris\n{"kind":"note"}\n```')).toBe("Done.");
  });

  it("shows an iris-show or iris-doc artifact fence and still cuts at the iris block after it", () => {
    const show = '```iris-show\n{"type":"callout","tone":"info","body":"x"}\n```';
    expect(visiblePrefix(`Look:\n\n${show}\n\nDone.`)).toBe(`Look:\n\n${show}\n\nDone.`);
    expect(visiblePrefix(`Look:\n\n\`\`\`iris-doc\n# d\n\`\`\`\n\n\`\`\`iris\n{}\n\`\`\``)).toBe(
      "Look:\n\n```iris-doc\n# d\n```",
    );
  });

  it("holds back a trailing fragment of the fence", () => {
    for (const tail of ["`", "``", "```", "```i", "```ir", "```iri", "```iris"]) {
      expect(visiblePrefix(`Done.${tail}`)).toBe("Done.");
    }
    expect(visiblePrefix("Use `code` now")).toBe("Use `code` now");
  });

  it("handles a fence split across deltas", () => {
    const parts = ["Done.\n\n``", "`iris\n", '{"kind":"note"}\n```'];
    let raw = "";
    const seen: string[] = [];
    for (const part of parts) {
      raw += part;
      seen.push(visiblePrefix(raw));
    }
    expect(seen).toEqual(["Done.", "Done.", "Done."]);
  });
});

function collect(intervalMs = 20) {
  const progress = createReplyProgress({ intervalMs });
  const events: ProgressEvent[] = [];
  progress.subscribe((e) => events.push(e));
  return { progress, events };
}

describe("createReplyProgress", () => {
  it("emits the first delta at once and coalesces the rest to one per interval", async () => {
    const { progress, events } = collect(30);
    const turn = progress.begin("m1");
    turn.onProgress({ type: "text", delta: "\n\nHel" });
    turn.onProgress({ type: "text", delta: "lo " });
    turn.onProgress({ type: "text", delta: "world" });
    expect(events).toEqual([{ type: "delta", id: "m1", attempt: 1, seq: 1, text: "Hel" }]);
    await sleep(60);
    expect(events).toEqual([
      { type: "delta", id: "m1", attempt: 1, seq: 1, text: "Hel" },
      { type: "delta", id: "m1", attempt: 1, seq: 2, text: "lo world" },
    ]);
    expect(progress.partial("m1")).toEqual({ attempt: 1, seq: 2, text: "Hello world" });
    turn.end();
  });

  it("finish emits the remainder of the reply at once; end drops the partial and any timer", async () => {
    const { progress, events } = collect(30);
    const turn = progress.begin("m1");
    turn.onProgress({ type: "text", delta: "Hi" });
    turn.onProgress({ type: "text", delta: " there" });
    turn.finish("Hi there");
    expect(events.map((e) => e.type === "delta" && e.text)).toEqual(["Hi", " there"]);
    turn.end();
    turn.end();
    expect(progress.partial("m1")).toBeNull();
    await sleep(50);
    expect(events).toHaveLength(2);
  });

  it("finish emits nothing when the reply does not extend what was sent", () => {
    const { progress, events } = collect();
    const turn = progress.begin("m1");
    turn.onProgress({ type: "text", delta: "abc" });
    turn.finish("xyz");
    turn.finish("abc");
    expect(events).toHaveLength(1);
  });

  it("never shows the fence, even split across deltas", async () => {
    const { progress, events } = collect(5);
    const turn = progress.begin("m1");
    for (const delta of ["\n\nDone.\n\n``", "`iris\n", '{"kind":"note"}\n```']) {
      turn.onProgress({ type: "text", delta });
      await sleep(10);
    }
    turn.finish("Done.");
    const text = events.flatMap((e) => (e.type === "delta" ? [e.text] : [])).join("");
    expect(text).toBe("Done.");
  });

  it("activity events are immediate and unthrottled", () => {
    const { progress, events } = collect(1000);
    const turn = progress.begin("m1");
    turn.onProgress({ type: "tool", tool: "a" });
    turn.onProgress({ type: "tool", tool: "b" });
    expect(events).toEqual([
      { type: "activity", id: "m1", attempt: 1, tool: "a" },
      { type: "activity", id: "m1", attempt: 1, tool: "b" },
    ]);
    expect(progress.partial("m1")).toBeNull();
  });

  it("counts attempts per memo and a newer turn is not clobbered by the old handle", () => {
    const { progress, events } = collect();
    const first = progress.begin("m1");
    first.onProgress({ type: "text", delta: "old" });
    const second = progress.begin("m1");
    second.onProgress({ type: "text", delta: "new" });
    first.onProgress({ type: "text", delta: "ignored" });
    first.end();
    expect(progress.partial("m1")).toEqual({ attempt: 2, seq: 1, text: "new" });
    expect(events.map((e) => e.attempt)).toEqual([1, 2]);
    expect(progress.begin("other").onProgress).toBeDefined();
    second.end();
  });

  it("a throwing listener never reaches the publisher", () => {
    const progress = createReplyProgress({ intervalMs: 1 });
    const seen: ProgressEvent[] = [];
    progress.subscribe(() => {
      throw new Error("boom");
    });
    progress.subscribe((e) => seen.push(e));
    progress.begin("m1").onProgress({ type: "tool", tool: "x" });
    expect(seen).toHaveLength(1);
  });
});
