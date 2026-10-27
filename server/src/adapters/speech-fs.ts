import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { SpeechCache } from "../ports/speaker.js";
import { writeAtomic } from "./fs-atomic.js";

const SAFE_ID = /^[0-9a-f-]{8,64}$/i;

/**
 * Speech lives at `<dir>/<id>.mp3`, with the text it was made from in `<dir>/<id>.txt`. The mp3 is
 * written first, so a crash in between leaves a text that no longer matches and the next read
 * is a miss rather than the wrong audio.
 */
export function createFsSpeechCache(dir: string): SpeechCache {
  const fileOf = (memoId: string, ext: "mp3" | "txt") => {
    if (!SAFE_ID.test(memoId)) throw new Error(`unsafe memo id: ${memoId}`);
    return join(dir, `${memoId}.${ext}`);
  };

  return {
    async get({ memoId, text }) {
      const stored = await readFile(fileOf(memoId, "txt"), "utf8").catch(() => null);
      if (stored !== text) return null;
      const bytes = await readFile(fileOf(memoId, "mp3")).catch(() => null);
      return bytes ? new Uint8Array(bytes) : null;
    },
    async put({ memoId, text, bytes }) {
      await writeAtomic(fileOf(memoId, "mp3"), bytes);
      await writeAtomic(fileOf(memoId, "txt"), text);
    },
  };
}
