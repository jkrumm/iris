import { describe, expect, it } from "bun:test";
import { createKeyedQueue, KeyedQueueFull, KeyedQueueTimeout } from "./keyed-queue.js";

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

/** A sleep that only finishes when the test fires it, or when the queue cancels it. */
function manualSleep() {
  const waits: { ms: number; signal: AbortSignal; fire: () => void }[] = [];
  const sleep = (ms: number, signal: AbortSignal) =>
    new Promise<void>((resolve) => {
      waits.push({ ms, signal, fire: resolve });
      signal.addEventListener("abort", () => resolve(), { once: true });
    });
  return { sleep, waits };
}

const gate = () => {
  let open!: () => void;
  const opened = new Promise<void>((resolve) => (open = resolve));
  return { opened, open };
};

describe("createKeyedQueue, bounded wait", () => {
  it("starts no timer for a caller that does not wait", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 100, sleep });
    await expect(queue("a", () => Promise.resolve(1))).resolves.toBe(1);
    expect(waits).toEqual([]);
  });

  it("lets a caller that is served in time run", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 100, sleep });
    const first = gate();
    const a1 = queue("a", () => first.opened.then(() => "one"));
    const a2 = queue("a", () => Promise.resolve("two"));
    expect(waits.map((w) => w.ms)).toEqual([100]);
    first.open();
    await expect(Promise.all([a1, a2])).resolves.toEqual(["one", "two"]);
    expect(waits[0]?.signal.aborted).toBe(true);
  });

  it("clears the wait of every served caller, even when the turn ahead failed", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 100, sleep });
    const first = gate();
    const a1 = queue("a", () => first.opened.then(() => Promise.reject(new Error("boom"))));
    const a2 = queue("a", () => Promise.resolve("two"));
    const a3 = queue("a", () => Promise.resolve("three"));
    expect(waits.map((w) => w.signal.aborted)).toEqual([false, false]);
    first.open();
    await expect(a1).rejects.toThrow("boom");
    await expect(Promise.all([a2, a3])).resolves.toEqual(["two", "three"]);
    expect(waits.map((w) => w.signal.aborted)).toEqual([true, true]);
  });

  it("fails a caller that waits past the bound, names the turn ahead and never runs its task", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 1500, sleep });
    const stuck = gate();
    const ran: string[] = [];
    const first = queue("thread-1", () => stuck.opened, { label: "memo m1" });
    const second = queue("thread-1", async () => void ran.push("m2"), { label: "memo m2" });

    waits[0]?.fire();
    const err = await second.catch((e: unknown) => e);
    expect(err).toBeInstanceOf(KeyedQueueTimeout);
    expect(err).toMatchObject({ key: "thread-1", waitedMs: 1500, ahead: "memo m1" });
    expect((err as Error).message).toBe(
      "thread thread-1 is busy: waited 1500 ms behind memo m1, which has not finished",
    );

    stuck.open();
    await first;
    expect(ran).toEqual([]);
  });

  it("keeps the line consistent: a later caller still waits for the stuck turn, then runs", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 1000, sleep });
    const stuck = gate();
    const order: string[] = [];
    const first = queue(
      "t",
      async () => {
        order.push("m1 start");
        await stuck.opened;
        order.push("m1 end");
      },
      { label: "memo m1" },
    );
    const second = queue("t", async () => void order.push("m2"), { label: "memo m2" });
    waits[0]?.fire();
    await expect(second).rejects.toBeInstanceOf(KeyedQueueTimeout);

    const third = queue("t", async () => void order.push("m3"), { label: "memo m3" });
    await Promise.resolve();
    expect(order).toEqual(["m1 start"]);

    stuck.open();
    await Promise.all([first, third]);
    expect(order).toEqual(["m1 start", "m1 end", "m3"]);
  });

  it("names the turn that is stuck, not one that already finished", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 1000, sleep });
    const stuck = gate();
    const m1 = queue("t", () => Promise.resolve(), { label: "memo m1" });
    const m2 = queue("t", () => stuck.opened, { label: "memo m2" });
    const m3 = queue("t", () => Promise.resolve(), { label: "memo m3" });
    await m1;
    waits[1]?.fire();
    await expect(m3).rejects.toMatchObject({ ahead: "memo m2" });
    stuck.open();
    await m2;
  });

  it("does not make other keys wait or time out", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ maxWaitMs: 1000, sleep });
    const stuck = gate();
    const a = queue("a", () => stuck.opened);
    await expect(queue("b", () => Promise.resolve("b"))).resolves.toBe("b");
    expect(waits).toEqual([]);
    stuck.open();
    await a;
  });

  it("is unbounded without maxWaitMs", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createKeyedQueue({ sleep });
    const first = gate();
    const a1 = queue("a", () => first.opened);
    const a2 = queue("a", () => Promise.resolve("two"));
    expect(waits).toEqual([]);
    first.open();
    await a1;
    await expect(a2).resolves.toBe("two");
  });
});

describe("createKeyedQueue, bounded depth", () => {
  it("rejects a caller past maxDepth without running its task, and frees the place when the line drains", async () => {
    const queue = createKeyedQueue({ maxDepth: 2 });
    const first = gate();
    const ran: string[] = [];
    const a1 = queue("a", () => first.opened);
    const a2 = queue("a", async () => void ran.push("a2"));
    const err = await queue("a", async () => void ran.push("a3")).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(KeyedQueueFull);
    expect(err).toMatchObject({ key: "a", depth: 2 });
    // Another key has its own line.
    await expect(queue("b", () => Promise.resolve("b"))).resolves.toBe("b");

    first.open();
    await Promise.all([a1, a2]);
    await expect(queue("a", () => Promise.resolve("again"))).resolves.toBe("again");
    expect(ran).toEqual(["a2"]);
  });
});

describe("createKeyedQueue, whileWaiting", () => {
  it("wraps only the time spent behind another task", async () => {
    const queue = createKeyedQueue();
    const events: string[] = [];
    const whileWaiting = async <T>(wait: Promise<T>) => {
      events.push("wait");
      const result = await wait;
      events.push("turn");
      return result;
    };
    const first = gate();
    const a1 = queue("a", () => first.opened, { whileWaiting });
    const a2 = queue("a", async () => void events.push("a2 ran"), { whileWaiting });
    await Promise.resolve();
    expect(events).toEqual(["wait"]);
    first.open();
    await Promise.all([a1, a2]);
    expect(events).toEqual(["wait", "turn", "a2 ran"]);
  });
});
