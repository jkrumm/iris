import { describe, expect, it } from "bun:test";
import { createSqliteFactoryPushStore } from "../adapters/sqlite-factory-pushes.js";
import { testStore } from "../memo/test-support.js";
import { FactoryError, type FactoryAsk } from "../ports/factory.js";
import { fakeFactoryAlerter, fakeFactoryReader } from "../ports/fakes.js";
import { decisionAsk } from "./test-support.js";
import { createFactoryWatcher } from "./watcher.js";

const quiet = () => {};

function setup(
  opts: { asks?: FactoryAsk[]; outcomes?: Parameters<typeof fakeFactoryAlerter>[0] } = {},
) {
  const { db, clock } = testStore();
  const reader = fakeFactoryReader({ asks: opts.asks ?? [] });
  const alerter = fakeFactoryAlerter(opts.outcomes);
  const build = () =>
    createFactoryWatcher({
      reader,
      alerter,
      pushes: createSqliteFactoryPushStore({ db, clock }),
      debounceMs: 5,
      pollMs: 10_000,
      backoffMs: { min: 5, max: 10 },
      logger: quiet,
    });
  return { db, reader, alerter, build };
}

const until = async (check: () => boolean) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((r) => setTimeout(r, 5));
  expect(check()).toBe(true);
};

/** `pass` alone is a scan after the baseline (only `start` runs the silent first scan). */
const running = async (opts: Parameters<typeof setup>[0] = {}) => setup(opts);

describe("factory watcher passes", () => {
  it("pushes a new decision ask once, however often it is read", async () => {
    const ctx = await running();
    const watcher = ctx.build();
    ctx.reader.state.asks = [decisionAsk()];
    await watcher.pass();
    await watcher.pass();
    expect(ctx.alerter.calls.map((c) => c.id)).toEqual([decisionAsk().id]);
  });

  it("does not push the same ask again after a restart", async () => {
    const ctx = await running();
    ctx.reader.state.asks = [decisionAsk()];
    await ctx.build().pass();
    await ctx.build().pass();
    expect(ctx.alerter.calls).toHaveLength(1);
  });

  it("never pushes the human queue, a stale ask, a non-decision source or an ask without an Issue", async () => {
    const ctx = await running();
    ctx.reader.state.asks = [
      decisionAsk({ id: "q", source: "queue", issue: null }),
      decisionAsk({ id: "s", stale: true }),
      decisionAsk({ id: "h", source: "hc" }),
      decisionAsk({ id: "n", issue: null }),
    ];
    await ctx.build().pass();
    expect(ctx.alerter.calls).toEqual([]);
  });

  it("retries after a transient failure and stops once delivered", async () => {
    const ctx = await running({ outcomes: { outcomes: ["retry"] } });
    const watcher = ctx.build();
    ctx.reader.state.asks = [decisionAsk()];
    await watcher.pass();
    await watcher.pass();
    await watcher.pass();
    expect(ctx.alerter.calls).toHaveLength(2);
  });

  it("marks an ask done when no device has a token or APNs refused it for good", async () => {
    const ctx = await running({ outcomes: { outcomes: ["no_token", "rejected"] } });
    const watcher = ctx.build();
    ctx.reader.state.asks = [decisionAsk({ id: "a" }), decisionAsk({ id: "b" })];
    await watcher.pass();
    await watcher.pass();
    expect(ctx.alerter.calls.map((c) => c.id)).toEqual(["a", "b"]);
  });

  it("survives a failing factory and an alerter that throws", async () => {
    const ctx = await running();
    const watcher = ctx.build();
    ctx.reader.state.failWith = new FactoryError("unavailable", "down");
    await watcher.pass();
    ctx.reader.state.failWith = undefined;
    ctx.reader.state.asks = [decisionAsk()];
    ctx.alerter.alert = async () => {
      throw new Error("boom");
    };
    await watcher.pass();
    expect(ctx.alerter.calls).toHaveLength(0);
  });
});

describe("factory watcher start", () => {
  it("records the asks open on the first ever start without pushing, then pushes new ones", async () => {
    const ctx = setup({ asks: [decisionAsk({ id: "old" })] });
    const watcher = ctx.build();
    watcher.start();
    await until(() => ctx.reader.follows.length > 0);
    expect(ctx.alerter.calls).toEqual([]);

    ctx.reader.state.asks = [decisionAsk({ id: "old" }), decisionAsk({ id: "new" })];
    ctx.reader.emit({ event: "fleet", cursor: "i1.s1" });
    await until(() => ctx.alerter.calls.length === 1);
    expect(ctx.alerter.calls[0]?.id).toBe("new");
    watcher.stop();
    await watcher.idle();

    // A restart: both are known, only a third is new.
    const again = ctx.build();
    ctx.reader.state.asks = [...ctx.reader.state.asks, decisionAsk({ id: "third" })];
    again.start();
    await until(() => ctx.alerter.calls.length === 2);
    expect(ctx.alerter.calls.map((c) => c.id)).toEqual(["new", "third"]);
    again.stop();
    await again.idle();
  });

  it("keeps the baseline silent until a scan succeeds", async () => {
    const ctx = setup({ asks: [decisionAsk({ id: "old" })] });
    ctx.reader.state.failWith = new FactoryError("unavailable", "down");
    const watcher = ctx.build();
    watcher.start();
    await new Promise((r) => setTimeout(r, 20));
    watcher.stop();
    await watcher.idle();

    // Restarted with the factory back: the old ask is still part of the baseline.
    ctx.reader.state.failWith = undefined;
    const again = ctx.build();
    again.start();
    await until(() => ctx.reader.follows.length > 1);
    expect(ctx.alerter.calls).toEqual([]);
    again.stop();
    await again.idle();
  });

  it("resumes the stream from the last cursor, and from now after a 410", async () => {
    const ctx = setup();
    const watcher = ctx.build();
    watcher.start();
    await until(() => ctx.reader.follows.length === 1);
    ctx.reader.emit({ event: "issue", cursor: "i5.s2" });
    ctx.reader.drop(new Error("connection lost"));
    await until(() => ctx.reader.follows.length === 2);
    expect(ctx.reader.follows).toEqual([undefined, "i5.s2"]);

    ctx.reader.drop(new FactoryError("cursor_gone", "gone"));
    await until(() => ctx.reader.follows.length === 3);
    expect(ctx.reader.follows[2]).toBeUndefined();
    watcher.stop();
    await watcher.idle();
  });
});
