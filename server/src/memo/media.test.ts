import { describe, expect, it } from "bun:test";
import type { Speaker } from "../ports/speaker.js";
import { fakeCombiner, fakeSpeechCache } from "../ports/fakes.js";
import { createMemoMedia } from "./media.js";
import { deferred, fakeAudio, seedMemo, testStore } from "./test-support.js";

const decode = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

function setup(speaker: Speaker) {
  const { store } = testStore();
  const media = createMemoMedia({
    store,
    audio: fakeAudio(),
    combiner: fakeCombiner(),
    speaker,
    speechCache: fakeSpeechCache(),
  });
  const memo = seedMemo(store, "summarized");
  const withReply = (replyText: string) =>
    store.completeStep({
      id: memo.id,
      step: "summarize",
      from: "summarized",
      to: "summarized",
      patch: { replyText },
    });
  return { media, memo, withReply };
}

describe("speech", () => {
  it("gives concurrent callers with different text their own audio", async () => {
    const started: string[] = [];
    const release = new Map<string, () => void>();
    const speaker: Speaker = {
      async speak({ text }) {
        started.push(text);
        const gate = deferred();
        release.set(text, () => gate.resolve());
        await gate.promise;
        return { bytes: new TextEncoder().encode(`mp3:${text}`) };
      },
    };
    const { media, memo, withReply } = setup(speaker);

    withReply("first text");
    const first = media.speech(memo.id);
    withReply("second text");
    const second = media.speech(memo.id);
    await Promise.resolve();
    await Promise.resolve();
    expect(started).toEqual(["first text", "second text"]);

    release.get("second text")?.();
    release.get("first text")?.();
    expect(decode(await first)).toBe("mp3:first text");
    expect(decode(await second)).toBe("mp3:second text");
  });

  it("still shares one synthesis between concurrent callers with the same text", async () => {
    const gate = deferred();
    let calls = 0;
    const speaker: Speaker = {
      async speak({ text }) {
        calls++;
        await gate.promise;
        return { bytes: new TextEncoder().encode(`mp3:${text}`) };
      },
    };
    const { media, memo, withReply } = setup(speaker);
    withReply("same text");

    const results = [media.speech(memo.id), media.speech(memo.id)];
    gate.resolve();
    expect((await Promise.all(results)).map(decode)).toEqual(["mp3:same text", "mp3:same text"]);
    expect(calls).toBe(1);
  });
});
