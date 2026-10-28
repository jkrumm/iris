import { describe, expect, it } from "bun:test";
import { createKeyedQueue } from "./keyed-queue.js";

describe("createKeyedQueue", () => {
  it("runs the tasks of one key in call order and the tasks of other keys alongside", async () => {
    const queue = createKeyedQueue();
    const order: string[] = [];
    let release!: () => void;
    const first = queue("a", async () => {
      order.push("a1 start");
      await new Promise<void>((resolve) => (release = resolve));
      order.push("a1 end");
    });
    const second = queue("a", async () => void order.push("a2"));
    const other = queue("b", async () => void order.push("b1"));

    await other;
    expect(order).toEqual(["a1 start", "b1"]);
    release();
    await Promise.all([first, second]);
    expect(order).toEqual(["a1 start", "b1", "a1 end", "a2"]);
  });

  it("hands a failure to its own caller only and still runs the next task", async () => {
    const queue = createKeyedQueue();
    const failed = queue("a", () => Promise.reject(new Error("boom")));
    const next = queue("a", () => Promise.resolve("ran"));
    await expect(failed).rejects.toThrow("boom");
    await expect(next).resolves.toBe("ran");
  });
});
