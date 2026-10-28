import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFsAssetStore } from "./assets-fs.js";

const memoId = "0f8fad5b-d9cb-469f-a165-70867728950e";
const [a, b] = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"] as [
  string,
  string,
];
let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "iris-assets-"));
});
afterEach(() => rm(dir, { recursive: true, force: true }));

describe("fs AssetStore", () => {
  it("reads back what it wrote under <dir>/<memo>/<asset>, and misses for an unknown asset", async () => {
    const store = createFsAssetStore(join(dir, "assets"));
    expect(await store.read({ memoId, assetId: a })).toBeNull();
    await store.put({ memoId, assetId: a, bytes: new Uint8Array([1, 2, 3]) });
    expect([...((await store.read({ memoId, assetId: a })) ?? [])]).toEqual([1, 2, 3]);
    expect(await readdir(join(dir, "assets", memoId))).toEqual([a]);
  });

  it("prunes every file that is not kept, and removes a memo's directory", async () => {
    const store = createFsAssetStore(dir);
    await store.put({ memoId, assetId: a, bytes: new Uint8Array([1]) });
    await store.put({ memoId, assetId: b, bytes: new Uint8Array([2]) });
    await store.prune({ memoId, keep: new Set([b]) });
    expect(await readdir(join(dir, memoId))).toEqual([b]);

    await store.removeAll(memoId);
    expect(await readdir(dir)).toEqual([]);
    await store.removeAll(memoId);
    await store.prune({ memoId, keep: new Set() });
  });

  it("removes named files only", async () => {
    const store = createFsAssetStore(dir);
    await store.put({ memoId, assetId: a, bytes: new Uint8Array([1]) });
    await store.put({ memoId, assetId: b, bytes: new Uint8Array([2]) });
    await store.remove({ memoId, assetIds: [a, "33333333-3333-4333-8333-333333333333"] });
    expect(await readdir(join(dir, memoId))).toEqual([b]);
  });

  it("reads an id that cannot name a file as a miss, and refuses to write one", async () => {
    const store = createFsAssetStore(dir);
    expect(await store.read({ memoId: "../x", assetId: a })).toBeNull();
    expect(await store.read({ memoId, assetId: "../../x" })).toBeNull();
    await expect(
      store.put({ memoId, assetId: "../../x", bytes: new Uint8Array() }),
    ).rejects.toThrow("unsafe asset id");
  });

  it("maps only a missing file to a miss: any other failure rejects", async () => {
    const store = createFsAssetStore(dir);
    // A file where the memo's directory should be: reading under it is ENOTDIR, not ENOENT.
    await writeFile(join(dir, memoId), "not a directory");
    await expect(store.read({ memoId, assetId: a })).rejects.toThrow();
    await expect(store.prune({ memoId, keep: new Set() })).rejects.toThrow();
  });
});
