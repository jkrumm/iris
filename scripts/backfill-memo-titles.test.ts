import { describe, expect, it } from "bun:test";
import { Database } from "bun:sqlite";
import { createSqliteMemoStore, openDatabase } from "../server/src/adapters/sqlite.js";
import { fakeSummarizer } from "../server/src/ports/fakes.js";
import { backfillTitles } from "./backfill-memo-titles.js";

const clock = { now: () => new Date("2026-11-16T12:00:00.000Z") };

function seed(
  db: Database,
  store: ReturnType<typeof createSqliteMemoStore>,
  init: { mode: "transcribe" | "hermes"; transcript: string; state?: string },
) {
  const id = crypto.randomUUID();
  store.createMemo({
    id,
    mode: init.mode,
    device: "iphone",
    startedAt: "2026-01-01T00:00:00.000Z",
  });
  db.query("UPDATE memos SET state = ?, transcript = ? WHERE id = ?").run(
    init.state ?? "notified",
    init.transcript,
    id,
  );
  return id;
}

function setup() {
  const db = openDatabase(":memory:");
  const store = createSqliteMemoStore({ db, clock });
  return { db, store };
}

describe("backfillTitles", () => {
  it("titles finished transcribe memos without a summary, adds a gist only for a long transcript, and is idempotent", async () => {
    const { db, store } = setup();
    const long = seed(db, store, { mode: "transcribe", transcript: "wort ".repeat(120) });
    const short = seed(db, store, { mode: "transcribe", transcript: "kurz" });
    const hermes = seed(db, store, { mode: "hermes", transcript: "bleibt" });
    const running = seed(db, store, {
      mode: "transcribe",
      transcript: "noch dran",
      state: "transcribed",
    });
    const summarizer = fakeSummarizer();

    const first = await backfillTitles({ db, summarizer, now: clock.now });
    expect(first).toEqual({ titled: 2, gisted: 1, failed: 0 });
    expect(store.getMemo(long)).toMatchObject({
      summary: { headline: "Headline" },
      transcriptGist: "Gist.",
      updatedAt: "2026-11-16T12:00:00.000Z",
    });
    expect(store.getMemo(short)).toMatchObject({
      summary: { headline: "Headline" },
      transcriptGist: null,
    });
    expect(store.getMemo(hermes)?.summary).toBeNull();
    expect(store.getMemo(running)?.summary).toBeNull();
    expect(store.listStepRecords(long).map((s) => [s.step, s.status])).toEqual([
      ["summarize", "done"],
    ]);
    expect(summarizer.calls.every((c) => c.replyText === null)).toBe(true);

    expect(await backfillTitles({ db, summarizer, now: clock.now })).toEqual({
      titled: 0,
      gisted: 0,
      failed: 0,
    });
    expect(summarizer.calls).toHaveLength(2);
  });

  it("leaves a memo whose summarize failed for the next run, and a failed gist still titles it", async () => {
    const { db, store } = setup();
    const id = seed(db, store, { mode: "transcribe", transcript: "wort ".repeat(120) });
    const down = fakeSummarizer({ failWith: new Error("agw down") });
    expect(await backfillTitles({ db, summarizer: down })).toEqual({
      titled: 0,
      gisted: 0,
      failed: 1,
    });
    expect(store.getMemo(id)?.summary).toBeNull();

    const noGist = fakeSummarizer({ gistFailWith: new Error("agw down") });
    expect(await backfillTitles({ db, summarizer: noGist })).toEqual({
      titled: 1,
      gisted: 0,
      failed: 0,
    });
    expect(store.getMemo(id)).toMatchObject({
      summary: { headline: "Headline" },
      transcriptGist: null,
    });
  });

  it("a dry run changes nothing", async () => {
    const { db, store } = setup();
    const id = seed(db, store, { mode: "transcribe", transcript: "kurz" });
    const summarizer = fakeSummarizer();
    expect(await backfillTitles({ db, summarizer, dryRun: true })).toEqual({
      titled: 1,
      gisted: 0,
      failed: 0,
    });
    expect(store.getMemo(id)?.summary).toBeNull();
    expect(summarizer.calls).toEqual([]);
  });
});
