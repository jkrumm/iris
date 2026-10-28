import { describe, expect, it } from "bun:test";
import { MemoError, type MemoErrorCode } from "./errors.js";
import { createMemoEvents, type MemoEvent } from "./events.js";
import { PURGE_AFTER_MS, type MemoState } from "./memo.js";
import { createRunner } from "./runner.js";
import { createMemoService } from "./service.js";
import { deferred, fakeAudio, parkMemo, seedMemo, testStore } from "./test-support.js";

function setup() {
  const { store, clock } = testStore();
  const events = createMemoEvents();
  const seen: MemoEvent[] = [];
  events.subscribe((e) => seen.push(e));
  const audio = fakeAudio();
  const runner = createRunner({ store, handlers: {}, events, clock });
  const service = createMemoService({
    store,
    runner,
    events,
    audio,
    clock,
    maxSegmentBytes: 16,
    destinations: ["hermes"],
  });
  return { store, clock, seen, service, audio };
}

const codeOf = (fn: () => unknown): MemoErrorCode | "no error" => {
  try {
    fn();
  } catch (err) {
    if (err instanceof MemoError) return err.code;
    throw err;
  }
  return "no error";
};

const codeOfAsync = async (fn: () => Promise<unknown>): Promise<MemoErrorCode | "no error"> => {
  try {
    await fn();
  } catch (err) {
    if (err instanceof MemoError) return err.code;
    throw err;
  }
  return "no error";
};

describe("setFlags", () => {
  it("sets the flags and publishes a flag-change event with the current state", () => {
    const { store, service, seen } = setup();
    const { id } = seedMemo(store, "notified");
    const memo = service.setFlags({ id, done: true, favorite: true });
    expect(memo).toMatchObject({ done: true, favorite: true, archivedAt: null });
    expect(seen).toEqual([
      expect.objectContaining({ id, state: "notified", step: null, flagChange: true }),
    ]);
  });

  it("flags a memo that is still in the pipeline", () => {
    const { store, service } = setup();
    const { id } = seedMemo(store, "routed");
    expect(service.setFlags({ id, favorite: true }).state).toBe("routed");
  });

  it("rejects an empty change, an unknown memo and a deleted memo", () => {
    const { store, service, seen } = setup();
    const { id } = seedMemo(store, "notified");
    expect(codeOf(() => service.setFlags({ id }))).toBe("bad_request");
    expect(codeOf(() => service.setFlags({ id: crypto.randomUUID(), done: true }))).toBe(
      "not_found",
    );
    service.delete(id);
    seen.length = 0;
    expect(codeOf(() => service.setFlags({ id, done: true }))).toBe("bad_state");
    expect(seen).toEqual([]);
  });
});

describe("delete", () => {
  it("soft-deletes a settled memo, keeps it readable and publishes", () => {
    const { store, clock, service, seen } = setup();
    for (const state of ["notified", "failed"] as const) {
      const { id } = seedMemo(store, state === "failed" ? "transcribed" : state);
      if (state === "failed") store.markStepFailed({ id, step: "route", error: "boom" });
      seen.length = 0;
      const deleted = service.delete(id);
      expect(deleted.deletedAt).toBe(clock.now().toISOString());
      expect(service.get(id).memo.deletedAt).toBe(deleted.deletedAt);
      expect(seen).toEqual([expect.objectContaining({ id, flagChange: true })]);
    }
    const parked = parkMemo(store, { reason: "unsure" });
    expect(service.delete(parked).deletedAt).not.toBeNull();
  });

  it("deletes a memo still receiving and refuses its later segment and complete", async () => {
    const { store, service, seen } = setup();
    const { id } = seedMemo(store, "receiving");
    store.recordSegment({ id, index: 0, bytes: 4, sha256: "x" });
    const deleted = service.delete(id);
    expect(deleted).toMatchObject({ state: "receiving" });
    expect(deleted.deletedAt).not.toBeNull();
    expect(seen).toEqual([expect.objectContaining({ id, flagChange: true })]);
    expect(codeOf(() => service.complete({ id, segmentCount: 1 }))).toBe("bad_state");
    expect(
      await codeOfAsync(() => service.putSegment({ id, index: 1, bytes: new Uint8Array(4) })),
    ).toBe("bad_state");
    expect(store.markReceived({ id, segmentCount: 1 })).toBe(false);
    expect(store.getMemo(id)?.state).toBe("receiving");
  });

  it("rejects a segment whose write was still in flight when the memo was deleted", async () => {
    const { store, service, audio } = setup();
    const { id } = seedMemo(store, "receiving");
    const gate = deferred();
    const put = audio.put.bind(audio);
    audio.put = async (params) => {
      await gate.promise;
      return put(params);
    };
    const late = codeOfAsync(() => service.putSegment({ id, index: 0, bytes: new Uint8Array(4) }));
    service.delete(id);
    gate.resolve();
    expect(await late).toBe("bad_state");
    expect(store.listSegmentIndices(id)).toEqual([]);
  });

  it("refuses a memo the pipeline is still working on", () => {
    const { store, service } = setup();
    const states: MemoState[] = ["received", "transcribed", "routed", "acted", "summarized"];
    for (const state of states) {
      const { id } = seedMemo(store, state);
      expect([state, codeOf(() => service.delete(id))]).toEqual([state, "bad_state"]);
      expect(store.getMemo(id)?.deletedAt).toBeNull();
    }
    expect(codeOf(() => service.delete(crypto.randomUUID()))).toBe("not_found");
  });

  it("is idempotent: a repeat returns the first deletedAt and publishes nothing", () => {
    const { store, clock, service, seen } = setup();
    const { id } = seedMemo(store, "notified");
    const first = service.delete(id);
    seen.length = 0;
    clock.advance(30_000);
    expect(service.delete(id).deletedAt).toBe(first.deletedAt ?? "");
    expect(seen).toEqual([]);
  });

  it("rejects retry and route on a deleted memo", () => {
    const { store, service } = setup();
    const failed = seedMemo(store, "transcribed").id;
    store.markStepFailed({ id: failed, step: "route", error: "boom" });
    service.delete(failed);
    expect(codeOf(() => service.retry({ id: failed, from: "route" }))).toBe("bad_state");

    const parked = parkMemo(store, { reason: "unsure" });
    service.delete(parked);
    expect(codeOf(() => service.route({ id: parked, destination: "hermes" }))).toBe("bad_state");
    expect(store.getMemo(parked)?.state).toBe("needs_route");
  });
});

describe("restore", () => {
  it("clears deletedAt, keeps the flags and publishes", () => {
    const { store, service, seen } = setup();
    const { id } = seedMemo(store, "notified");
    service.setFlags({ id, favorite: true });
    service.delete(id);
    seen.length = 0;
    const restored = service.restore(id);
    expect(restored).toMatchObject({ deletedAt: null, favorite: true });
    expect(seen).toEqual([expect.objectContaining({ id, flagChange: true })]);
    expect(service.list({}).memos.map((m) => m.id)).toEqual([id]);
  });

  it("is a conflict for a memo that is not deleted and not found for an unknown one", () => {
    const { store, service } = setup();
    const { id } = seedMemo(store, "notified");
    expect(codeOf(() => service.restore(id))).toBe("bad_state");
    expect(codeOf(() => service.restore(crypto.randomUUID()))).toBe("not_found");
  });

  it("works until the undo window is over, then the memo counts as purged", () => {
    const { store, clock, service } = setup();
    const { id } = seedMemo(store, "notified");
    service.delete(id);
    clock.advance(PURGE_AFTER_MS - 1);
    expect(service.restore(id).deletedAt).toBeNull();

    service.delete(id);
    clock.advance(PURGE_AFTER_MS);
    expect(codeOf(() => service.restore(id))).toBe("not_found");
    expect(store.getMemo(id)?.deletedAt).not.toBeNull();
  });
});

describe("list", () => {
  it("passes the filters through", () => {
    const { store, service } = setup();
    const a = seedMemo(store, "notified").id;
    seedMemo(store, "notified");
    service.setFlags({ id: a, favorite: true, archived: true });
    expect(service.list({ favorite: true }).memos).toEqual([]);
    expect(service.list({ favorite: true, archived: true }).memos.map((m) => m.id)).toEqual([a]);
  });
});
