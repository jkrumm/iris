import { readdir, readFile, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import type { AssetStore } from "../ports/assets.js";
import { writeAtomic } from "./fs-atomic.js";

/** Directories stat-ed at once by `listMemos`: a data dir with thousands of memos must not open thousands of handles together. */
const STAT_BATCH = 32;

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
    async listMemos() {
      let entries;
      try {
        entries = await readdir(dir, { withFileTypes: true });
      } catch (err) {
        if (missing(err)) return [];
        throw err;
      }
      const names = entries
        .filter((entry) => entry.isDirectory() && SAFE_ID.test(entry.name))
        .map((entry) => entry.name);
      const memos: { name: string; changed: number }[] = [];
      for (let start = 0; start < names.length; start += STAT_BATCH) {
        const batch = await Promise.all(
          names.slice(start, start + STAT_BATCH).map(async (name) => {
            try {
              return { name, changed: (await stat(join(dir, name))).mtimeMs };
            } catch (err) {
              // A directory that vanishes between the two calls is not a memo to sweep; any other failure is the caller's.
              if (missing(err)) return null;
              throw err;
            }
          }),
        );
        for (const memo of batch) if (memo) memos.push(memo);
      }
      return memos.sort((a, b) => b.changed - a.changed).map((memo) => memo.name);
    },
    async list(memoId) {
      try {
        return await readdir(memoDir(memoId));
      } catch (err) {
        if (missing(err)) return [];
        throw err;
      }
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
