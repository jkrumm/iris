import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFsSpeechCache } from "./speech-fs.js";

const memoId = "0f8fad5b-d9cb-469f-a165-70867728950e";
let dir: string;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "iris-speech-"));
});
afterEach(() => rm(dir, { recursive: true, force: true }));

describe("fs SpeechCache", () => {
  it("misses, then hits for the same text, writing <id>.mp3 without leftovers", async () => {
    const cache = createFsSpeechCache(join(dir, "speech"));
    expect(await cache.get({ memoId, text: "Hello." })).toBeNull();

    await cache.put({ memoId, text: "Hello.", bytes: new Uint8Array([1, 2, 3]) });
    expect([...((await cache.get({ memoId, text: "Hello." })) ?? [])]).toEqual([1, 2, 3]);
    expect((await readdir(join(dir, "speech"))).toSorted()).toEqual([
      `${memoId}.mp3`,
      `${memoId}.txt`,
    ]);
  });

  it("misses for other text and is replaced by the new entry", async () => {
    const cache = createFsSpeechCache(dir);
    await cache.put({ memoId, text: "First.", bytes: new Uint8Array([1]) });
    expect(await cache.get({ memoId, text: "Second." })).toBeNull();

    await cache.put({ memoId, text: "Second.", bytes: new Uint8Array([2]) });
    expect(await cache.get({ memoId, text: "First." })).toBeNull();
    expect([...((await cache.get({ memoId, text: "Second." })) ?? [])]).toEqual([2]);
  });

  it("misses when the audio is gone and rejects unsafe ids", async () => {
    const cache = createFsSpeechCache(dir);
    await writeFile(join(dir, `${memoId}.txt`), "Hello.");
    expect(await cache.get({ memoId, text: "Hello." })).toBeNull();
    await expect(
      cache.put({ memoId: "../etc", text: "x", bytes: new Uint8Array([1]) }),
    ).rejects.toThrow();
  });
});
