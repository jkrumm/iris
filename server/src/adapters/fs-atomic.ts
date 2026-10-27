import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/** Atomic: a reader sees the previous file or the new one, never a partial write. Creates the directory. */
export async function writeAtomic(file: string, data: Uint8Array | string): Promise<void> {
  await mkdir(dirname(file), { recursive: true });
  const tmp = `${file}.${crypto.randomUUID()}.tmp`;
  try {
    await writeFile(tmp, data);
    await rename(tmp, file);
  } catch (err) {
    await rm(tmp, { force: true });
    throw err;
  }
}
