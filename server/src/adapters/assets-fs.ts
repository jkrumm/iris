import { readdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import type { AssetStore } from "../ports/assets.js";
import { writeAtomic } from "./fs-atomic.js";

const SAFE_ID = /^[0-9a-f-]{8,64}$/i;

/** Only a missing file or directory is "not there"; a permission or I/O error must reach the caller. */
const missing = (err: unknown) => (err as NodeJS.ErrnoException | undefined)?.code === "ENOENT";

/** Assets live at `<dir>/<memo id>/<asset id>`; both ids are checked before they become a path. */
export function createFsAssetStore(dir: string): AssetStore {
  const memoDir = (memoId: string) => {
    if (!SAFE_ID.test(memoId)) throw new Error(`unsafe memo id: ${memoId}`);
    return join(dir, memoId);
  };
  const fileOf = (memoId: string, assetId: string) => {
    if (!SAFE_ID.test(assetId)) throw new Error(`unsafe asset id: ${assetId}`);
    return join(memoDir(memoId), assetId);
  };

  return {
    async put({ memoId, assetId, bytes }) {
      await writeAtomic(fileOf(memoId, assetId), bytes);
    },
    async read({ memoId, assetId }) {
      // An id that can never name a file is a miss, not a failure.
      if (!SAFE_ID.test(memoId) || !SAFE_ID.test(assetId)) return null;
      try {
        return new Uint8Array(await readFile(fileOf(memoId, assetId)));
      } catch (err) {
        if (missing(err)) return null;
        throw err;
      }
    },
    async remove({ memoId, assetIds }) {
      await Promise.all(assetIds.map((assetId) => rm(fileOf(memoId, assetId), { force: true })));
    },
    async prune({ memoId, keep }) {
      let names: string[];
      try {
        names = await readdir(memoDir(memoId));
      } catch (err) {
        if (missing(err)) return;
        throw err;
      }
      await Promise.all(
        names
          .filter((name) => !keep.has(name))
          .map((name) => rm(join(memoDir(memoId), name), { force: true })),
      );
    },
    async removeAll(memoId) {
      await rm(memoDir(memoId), { recursive: true, force: true });
    },
  };
}
