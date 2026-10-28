import { readdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import type { AssetStore } from "../ports/assets.js";
import { writeAtomic } from "./fs-atomic.js";

const SAFE_ID = /^[0-9a-f-]{8,64}$/i;

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
      const bytes = await readFile(fileOf(memoId, assetId)).catch(() => null);
      return bytes ? new Uint8Array(bytes) : null;
    },
    async prune({ memoId, keep }) {
      const names = await readdir(memoDir(memoId)).catch(() => []);
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
