import { describe, expect, it } from "bun:test";
import { fakeAssetStore, fakeSpeechCache } from "../ports/fakes.js";
import { PURGE_AFTER_MS } from "./memo.js";
import { createPurger } from "./purge.js";
import { captureLogs, fakeAudio, seedMemo, testStore } from "./test-support.js";

const bytes = new Uint8Array([1, 2, 3]);

function setup() {
  const ctx = testStore();
  const audio = fakeAudio();
  const speechCache = fakeSpeechCache();
  const assets = fakeAssetStore();
  const purger = createPurger({
    store: ctx.store,
    audio,
    speechCache,
    assets,
    clock: ctx.clock,
    intervalMs: 20,
  });
  /** A notified memo with a segment, a combined recording and speech, deleted now. */
  const deletedMemo = async () => {
    const { id } = seedMemo(ctx.store, "notified");
    ctx.store.recordSegment({ id, index: 0, bytes: bytes.length, sha256: "x" });
    await audio.put({ id, index: 0, bytes });
    await audio.putCombined({ id, bytes });
    await speechCache.put({ memoId: id, text: "hi", bytes });
    await assets.put({ memoId: id, assetId: "a-1", bytes });
    ctx.store.markDeleted({ id, at: ctx.clock.now().toISOString() });
    return id;
  };
  return { ...ctx, audio, speechCache, assets, purger, deletedMemo };
}

describe("sweep", () => {
  it("keeps a deleted memo until its undo window is over", async () => {
    const { store, clock, audio, purger, deletedMemo } = setup();
    const id = await deletedMemo();
    clock.advance(PURGE_AFTER_MS - 1);
    expect(await purger.sweep()).toEqual([]);
    expect(store.getMemo(id)).not.toBeNull();
    expect(audio.files.size).toBe(1);
  });

  it("removes the audio, the speech, the reply assets and the rows once the window is over, and logs it", async () => {
    const { store, clock, audio, speechCache, assets, purger, deletedMemo, db } = setup();
    const id = await deletedMemo();
    const kept = seedMemo(store, "notified").id;
    clock.advance(PURGE_AFTER_MS);
    const { result, lines } = await captureLogs(() => purger.sweep());
    expect(result).toEqual([id]);
    expect(lines.filter((l) => l["event"] === "memo.purged")).toEqual([
      expect.objectContaining({ memo_id: id }),
    ]);
    expect(store.getMemo(id)).toBeNull();
    expect(store.getMemo(kept)).not.toBeNull();
    expect(audio.files.size).toBe(0);
    expect(audio.combined.size).toBe(0);
    expect(speechCache.entries.size).toBe(0);
    expect(assets.files.size).toBe(0);
    expect(db.query("SELECT * FROM segments WHERE memo_id = ?").all(id)).toEqual([]);
    expect(db.query("SELECT * FROM memo_steps WHERE memo_id = ?").all(id)).toEqual([]);
  });

  it("does not purge a restored memo", async () => {
    const { store, clock, audio, purger, deletedMemo } = setup();
    const id = await deletedMemo();
    clock.advance(PURGE_AFTER_MS - 1_000);
    store.restore(id);
    clock.advance(PURGE_AFTER_MS);
    expect(await purger.sweep()).toEqual([]);
    expect(store.getMemo(id)).not.toBeNull();
    expect(audio.files.size).toBe(1);
  });

  it("leaves the rows when removing the files fails, retries next pass and goes on with the others", async () => {
    const { store, clock, audio, purger, deletedMemo } = setup();
    const broken = await deletedMemo();
    const fine = await deletedMemo();
    const remove = audio.remove;
    audio.remove = async (id) => {
      if (id === broken) throw new Error("disk gone");
      await remove(id);
    };
    clock.advance(PURGE_AFTER_MS);
    const { result, lines } = await captureLogs(() => purger.sweep());
    expect(result).toEqual([fine]);
    expect(lines.some((l) => l["event"] === "memo.purge_failed" && l["memo_id"] === broken)).toBe(
      true,
    );
    expect(store.getMemo(broken)).not.toBeNull();

    audio.remove = remove;
    expect(await purger.sweep()).toEqual([broken]);
    expect(store.getMemo(broken)).toBeNull();
  });

  it("runs one pass at a time", async () => {
    const { clock, purger, deletedMemo } = setup();
    const id = await deletedMemo();
    clock.advance(PURGE_AFTER_MS);
    const [a, b] = await Promise.all([purger.sweep(), purger.sweep()]);
    expect([a, b]).toEqual([[id], [id]]);
  });
});

describe("a pass that cannot list", () => {
  it("rejects sweep() and the timer logs memo.sweep_failed, then keeps ticking", async () => {
    const { store, clock, audio, speechCache } = setup();
    let calls = 0;
    const failing = {
      ...store,
      listPurgeable: (): string[] => {
        calls++;
        throw new Error("db locked");
      },
    };
    const purger = createPurger({
      store: failing,
      audio,
      speechCache,
      assets: fakeAssetStore(),
      clock,
      intervalMs: 20,
    });
    await expect(purger.sweep()).rejects.toThrow("db locked");

    const { lines } = await captureLogs(async () => {
      purger.start();
      await Bun.sleep(60);
      purger.stop();
      await purger.idle();
    });
    const failed = lines.filter((l) => l["event"] === "memo.sweep_failed");
    expect(failed.length).toBeGreaterThanOrEqual(2);
    expect(failed[0]).toMatchObject({ error: "Error: db locked" });
    expect(calls).toBeGreaterThanOrEqual(3);
  });
});

describe("start and stop", () => {
  it("sweeps on start and on every interval until stopped", async () => {
    const { store, clock, purger, deletedMemo } = setup();
    const early = await deletedMemo();
    clock.advance(PURGE_AFTER_MS);
    purger.start();
    purger.start();
    await purger.idle();
    expect(store.getMemo(early)).toBeNull();

    const late = await deletedMemo();
    clock.advance(PURGE_AFTER_MS);
    await Bun.sleep(60);
    await purger.idle();
    expect(store.getMemo(late)).toBeNull();

    purger.stop();
    const after = await deletedMemo();
    clock.advance(PURGE_AFTER_MS);
    await Bun.sleep(60);
    await purger.idle();
    expect(store.getMemo(after)).not.toBeNull();
  });
});
