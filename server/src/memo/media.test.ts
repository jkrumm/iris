import { describe, expect, it } from "bun:test";
import type { Speaker } from "../ports/speaker.js";
import { fakeAssetStore, fakeCombiner, fakeSpeechCache } from "../ports/fakes.js";
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
    assets: fakeAssetStore(),
  });
  const memo = seedMemo(store, "summarized");
  const withReply = (replyText: string, spoken?: string) =>
    store.completeStep({
      id: memo.id,
      step: "summarize",
      from: "summarized",
      to: "summarized",
      patch: {
        replyText,
        ...(spoken ? { summary: { headline: "h", detail: "d", spoken } } : {}),
      },
    });
  return { media, memo, withReply };
}

function countingSpeaker() {
  const texts: string[] = [];
  const speaker: Speaker = {
    async speak({ text }) {
      texts.push(text);
      return { bytes: new TextEncoder().encode(`mp3:${text}`) };
    },
  };
  return { speaker, texts };
}

describe("recording", () => {
  it("refuses a typed memo: it has no segments to combine", async () => {
    const { store } = testStore();
    const combiner = fakeCombiner();
    const media = createMemoMedia({
      store,
      audio: fakeAudio(),
      combiner,
      speechCache: fakeSpeechCache(),
      assets: fakeAssetStore(),
    });
    const { memo } = store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "auto",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "kauf Milch",
    });
    const error = await media.recording(memo.id).catch((err: unknown) => err);
    expect(error).toMatchObject({ code: "bad_state" });
    expect(combiner.calls).toEqual([]);
  });
});

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

  it("speaks the speech-ready variant of a markdown reply, never the markdown", async () => {
    const { speaker, texts } = countingSpeaker();
    const { media, memo, withReply } = setup(speaker);
    withReply("Das ist **gut**, siehe [Doku](https://example.com).\n\n```ts\nconst a = 1;\n```");
    await media.speech(memo.id);
    expect(texts).toEqual(["Das ist gut, siehe Doku.\n\nein Codeblock"]);
  });

  it("speaks the triage summary plus 'details on screen' for a long reply", async () => {
    const { speaker, texts } = countingSpeaker();
    const { media, memo, withReply } = setup(speaker);
    withReply(
      "Das ist ein langer Satz über die Migration. ".repeat(30),
      "Die Migration ist fertig.",
    );
    await media.speech(memo.id);
    expect(texts).toEqual(["Die Migration ist fertig. Details auf dem Bildschirm."]);
  });

  it("speaks the clipped reply of a long answer whose summary failed, instead of a 409", async () => {
    const { speaker, texts } = countingSpeaker();
    const { media, memo, withReply } = setup(speaker);
    withReply("Das ist ein langer Satz über die Migration. ".repeat(30));
    await media.speech(memo.id);
    expect(texts).toHaveLength(1);
    expect(texts[0]?.length).toBeLessThanOrEqual(600);
    expect(texts[0]?.endsWith(" Details auf dem Bildschirm.")).toBe(true);
  });

  it("re-synthesizes when a retry changes the variant and hits the cache when it does not", async () => {
    const { speaker, texts } = countingSpeaker();
    const { media, memo, withReply } = setup(speaker);
    withReply("Erste **Antwort**.");
    await media.speech(memo.id);
    withReply("Erste Antwort."); // different markdown, same variant
    await media.speech(memo.id);
    expect(texts).toEqual(["Erste Antwort."]);
    withReply("Zweite Antwort.");
    expect(decode(await media.speech(memo.id))).toBe("mp3:Zweite Antwort.");
    expect(texts).toEqual(["Erste Antwort.", "Zweite Antwort."]);
  });
});
