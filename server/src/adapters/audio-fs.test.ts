import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFsAudioStore } from "./audio-fs.js";

const id = "0f8fad5b-d9cb-469f-a165-70867728950e";
let root: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "iris-audio-"));
});
afterEach(() => rm(root, { recursive: true, force: true }));

describe("fs AudioStore", () => {
  it("writes zero-padded .m4a files and overwrites in place without leftovers", async () => {
    const audio = createFsAudioStore(root);
    await audio.put({ id, index: 7, bytes: new Uint8Array([1, 2, 3]) });
    await audio.put({ id, index: 7, bytes: new Uint8Array([9]) });
    const file = audio.path({ id, index: 7 });
    expect(file).toBe(join(root, id, "000007.m4a"));
    expect([...(await readFile(file))]).toEqual([9]);
    expect(await readdir(join(root, id))).toEqual(["000007.m4a"]);
  });

  it("removes a memo's directory and tolerates unknown ids", async () => {
    const audio = createFsAudioStore(root);
    await audio.put({ id, index: 0, bytes: new Uint8Array([1]) });
    await audio.remove(id);
    expect(await readdir(root)).toEqual([]);
    await audio.remove(id);
  });

  it("rejects ids and indices that could escape the root", async () => {
    const audio = createFsAudioStore(root);
    await expect(
      audio.put({ id: "../etc", index: 0, bytes: new Uint8Array([1]) }),
    ).rejects.toThrow();
    await expect(audio.put({ id, index: -1, bytes: new Uint8Array([1]) })).rejects.toThrow();
    expect(() => audio.path({ id, index: 1.5 })).toThrow();
  });

  it("stores the combined recording next to the segments and reads it back as a sliceable file", async () => {
    const audio = createFsAudioStore(root);
    expect(await audio.readCombined(id)).toBeNull();
    await audio.putCombined({ id, bytes: new Uint8Array([1, 2, 3, 4, 5]) });
    await audio.putCombined({ id, bytes: new Uint8Array([10, 11, 12, 13, 14]) });
    expect(await readdir(join(root, id))).toEqual(["combined.m4a"]);

    const combined = await audio.readCombined(id);
    expect(combined?.size).toBe(5);
    const part = new Response(combined?.slice(1, 3));
    expect([...new Uint8Array(await part.arrayBuffer())]).toEqual([11, 12]);
  });

  it("drops the combined recording with the segments", async () => {
    const audio = createFsAudioStore(root);
    await audio.put({ id, index: 0, bytes: new Uint8Array([1]) });
    await audio.putCombined({ id, bytes: new Uint8Array([1]) });
    await audio.remove(id);
    expect(await audio.readCombined(id)).toBeNull();
  });
});
