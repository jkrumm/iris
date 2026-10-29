import { describe, expect, it } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { manualClock } from "../ports/clock.js";
import { createSqliteMemoStore } from "./sqlite.js";
import { repairFailedSummaries } from "./sqlite-repair.js";

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "iris-repair-"));
  const clock = manualClock();
  const db = new Database(join(dir, "iris.db"));
  const store = createSqliteMemoStore({ db, clock });
  const failedSummarize = (replyText: string | null) => {
    const id = crypto.randomUUID();
    store.createMemo({ id, mode: "auto", device: "iphone", startedAt: "2026-01-01T00:00:00.000Z" });
    store.markReceived({ id, segmentCount: 1 });
    store.transition({ id, from: "received", to: "transcribed" });
    store.transition({ id, from: "transcribed", to: "routed" });
    store.completeStep({
      id,
      step: "act",
      from: "routed",
      to: "acted",
      patch: { route: "hermes", ...(replyText !== null && { replyText }) },
    });
    store.markStepStarted({ id, step: "summarize" });
    store.markStepFailed({ id, step: "summarize", error: "402" });
    return id;
  };
  const backups = () => readdirSync(dir).filter((f) => f.startsWith("iris.db.bak-"));
  return { dir, db, clock, store, failedSummarize, backups };
}

describe("repairFailedSummaries", () => {
  it("moves failed(summarize) memos with a reply to notified, keeps the failed step, and backs up first", () => {
    const { dir, db, clock, store, failedSummarize, backups } = setup();
    const withReply = failedSummarize("Erledigt.");
    const noReply = failedSummarize(null);
    const blankReply = failedSummarize("  ");
    const newlineReply = failedSummarize("\n\t \r\n");

    expect(repairFailedSummaries({ db, clock, dataDir: dir })).toBe(1);

    expect(store.getMemo(withReply)).toMatchObject({
      state: "notified",
      failedStep: null,
      error: null,
    });
    expect(store.listStepRecords(withReply).find((s) => s.step === "summarize")).toMatchObject({
      status: "failed",
      error: "402",
    });
    expect(store.getMemo(noReply)).toMatchObject({ state: "failed", failedStep: "summarize" });
    expect(store.getMemo(blankReply)).toMatchObject({ state: "failed", failedStep: "summarize" });
    expect(store.getMemo(newlineReply)).toMatchObject({ state: "failed", failedStep: "summarize" });

    // The backup is a database as it was before the repair.
    expect(backups()).toHaveLength(1);
    const backup = join(dir, backups()[0] ?? "");
    expect(existsSync(backup)).toBe(true);
    const copy = new Database(backup, { readonly: true });
    try {
      expect(
        copy
          .query<{ state: string }, [string]>("SELECT state FROM memos WHERE id = ?")
          .get(withReply),
      ).toEqual({ state: "failed" });
    } finally {
      copy.close();
      db.close();
    }
  });

  it("is idempotent and writes no backup when nothing matches", () => {
    const { dir, db, clock, failedSummarize, backups } = setup();
    expect(repairFailedSummaries({ db, clock, dataDir: dir })).toBe(0);
    expect(backups()).toEqual([]);

    failedSummarize("Erledigt.");
    expect(repairFailedSummaries({ db, clock, dataDir: dir })).toBe(1);
    expect(repairFailedSummaries({ db, clock, dataDir: dir })).toBe(0);
    expect(backups()).toHaveLength(1);
    db.close();
  });
});
