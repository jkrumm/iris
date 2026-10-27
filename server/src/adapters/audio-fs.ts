import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AudioStore } from "../ports/audio.js";

const SAFE_ID = /^[0-9a-f-]{8,64}$/i;

/** Segments live at `<root>/<id>/<index, 6 digits>.m4a`. */
export function createFsAudioStore(root: string): AudioStore {
  const dirOf = (id: string) => {
    if (!SAFE_ID.test(id)) throw new Error(`unsafe memo id: ${id}`);
    return join(root, id);
  };
  const pathOf = ({ id, index }: { id: string; index: number }) => {
    if (!Number.isInteger(index) || index < 0 || index > 999_999) {
      throw new Error(`segment index out of range: ${index}`);
    }
    return join(dirOf(id), `${String(index).padStart(6, "0")}.m4a`);
  };

  return {
    async put({ id, index, bytes }) {
      const file = pathOf({ id, index });
      await mkdir(dirOf(id), { recursive: true });
      const tmp = `${file}.${crypto.randomUUID()}.tmp`;
      try {
        await writeFile(tmp, bytes);
        await rename(tmp, file);
      } catch (err) {
        await rm(tmp, { force: true });
        throw err;
      }
    },
    path: pathOf,
    async remove(id) {
      await rm(dirOf(id), { recursive: true, force: true });
    },
  };
}
