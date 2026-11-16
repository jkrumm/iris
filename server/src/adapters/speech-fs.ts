import { readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { SPEECH_VARIANTS, type SpeechVariant } from "../memo/speech-text.js";
import type { SpeechCache } from "../ports/speaker.js";
import { writeAtomic } from "./fs-atomic.js";

const SAFE_ID = /^[0-9a-f-]{8,64}$/i;

/**
 * Speech lives at `<dir>/<id>.mp3` (the request that names no variant) and `<dir>/<id>.<variant>.mp3`, each with the
 * text it was made from beside it as `.txt`. The mp3 is written first, so a crash in between leaves a text that no
 * longer matches and the next read is a miss rather than the wrong audio.
 */
export function createFsSpeechCache(dir: string): SpeechCache {
  const fileOf = (memoId: string, variant: SpeechVariant | undefined, ext: "mp3" | "txt") => {
    if (!SAFE_ID.test(memoId)) throw new Error(`unsafe memo id: ${memoId}`);
    return join(dir, `${memoId}${variant ? `.${variant}` : ""}.${ext}`);
  };

  return {
    async get({ memoId, variant, text }) {
      const stored = await readFile(fileOf(memoId, variant, "txt"), "utf8").catch(() => null);
      if (stored !== text) return null;
      const bytes = await readFile(fileOf(memoId, variant, "mp3")).catch(() => null);
      return bytes ? new Uint8Array(bytes) : null;
    },
    async put({ memoId, variant, text, bytes }) {
      await writeAtomic(fileOf(memoId, variant, "mp3"), bytes);
      await writeAtomic(fileOf(memoId, variant, "txt"), text);
    },
    async remove(memoId) {
      const variants = [undefined, ...SPEECH_VARIANTS];
      await Promise.all(
        variants.flatMap((variant) =>
          (["mp3", "txt"] as const).map((ext) => rm(fileOf(memoId, variant, ext), { force: true })),
        ),
      );
    },
  };
}
