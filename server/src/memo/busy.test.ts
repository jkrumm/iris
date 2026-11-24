import { describe, expect, it } from "bun:test";
import { createApp } from "../app.js";
import { seedMemo, testStore } from "./test-support.js";
import { createBusyCount } from "./busy.js";
import { TAKE_ACTIVE_MS } from "./memo.js";

describe("/health inflight counts a take in progress", () => {
  const setup = () => {
    const { store, clock } = testStore();
    const busy = createBusyCount({ stepsRunning: () => 0, store, clock });
    const app = createApp({ deviceTokens: new Map(), memos: {} as never, inflight: busy });
    const inflight = async () =>
      (
        (await (await app.handle(new Request("http://iris.test/health"))).json()) as {
          inflight: number;
        }
      ).inflight;
    return { store, clock, inflight };
  };

  it("is busy while a receiving memo's last segment is under the window old, idle after it", async () => {
    const { store, clock, inflight } = setup();
    expect(await inflight()).toBe(0);

    const { id } = seedMemo(store, "receiving");
    store.recordSegment({ id, index: 0, bytes: 10, sha256: "a" });
    expect(await inflight()).toBe(1);

    clock.advance(TAKE_ACTIVE_MS - 1000);
    expect(await inflight()).toBe(1);

    clock.advance(2000);
    expect(await inflight()).toBe(0);

    store.recordSegment({ id, index: 1, bytes: 10, sha256: "b" });
    expect(await inflight()).toBe(1);
  });

  it("stops counting once the take is complete", async () => {
    const { store, inflight } = setup();
    const { id } = seedMemo(store, "receiving");
    store.recordSegment({ id, index: 0, bytes: 10, sha256: "a" });
    expect(await inflight()).toBe(1);
    store.markReceived({ id, segmentCount: 1 });
    expect(await inflight()).toBe(0);
  });

  it("adds the memos with a step running", async () => {
    const { store, clock } = setup();
    const busy = createBusyCount({ stepsRunning: () => 2, store, clock });
    seedMemo(store, "receiving");
    expect(busy()).toBe(3);
  });
});
