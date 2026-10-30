import type { AssetStore } from "../ports/assets.js";
import type { DiagramRenderer } from "../ports/diagram.js";
import { log } from "../telemetry/log.js";
import { createKeyedQueue } from "./keyed-queue.js";
import type { ReplyAsset } from "./memo.js";
import type { MemoStore } from "./store.js";

/** More Mermaid fences than this in one reply: the rest stay code blocks (a bound on the work one reply can cause). */
export const MAX_BLOCKS = 12;

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*(.*)$/;

/**
 * The source of every top-level ```mermaid fence of a markdown reply, in document order (CommonMark: a fence closes on
 * the same character, at least as long, with nothing after it; an unclosed one runs to the end). A mermaid fence inside
 * another fenced block is that block's text, not a diagram.
 */
export function extractMermaidBlocks(markdown: string): string[] {
  const blocks: string[] = [];
  let open: { marker: string; mermaid: boolean; lines: string[] } | null = null;
  for (const line of markdown.split(/\r?\n/)) {
    if (open) {
      const closing = FENCE.exec(line);
      const isClose =
        closing?.[1] !== undefined &&
        closing[1].startsWith(open.marker[0] as string) &&
        closing[1].length >= open.marker.length &&
        closing[2] === "";
      if (!isClose) {
        open.lines.push(line);
        continue;
      }
      if (open.mermaid) blocks.push(open.lines.join("\n"));
      open = null;
      continue;
    }
    const opening = FENCE.exec(line);
    if (!opening?.[1]) continue;
    const info = opening[2] ?? "";
    // A backtick fence's info string cannot contain a backtick.
    if (opening[1].startsWith("`") && info.includes("`")) continue;
    open = {
      marker: opening[1],
      mermaid: info.split(/\s+/)[0]?.toLowerCase() === "mermaid",
      lines: [],
    };
  }
  if (open?.mermaid) blocks.push(open.lines.join("\n"));
  return blocks;
}

/** Rows examined per boot sweep: a bound on the render work one start-up can cause. */
export const BACKFILL_LIMIT = 50;

/** Memo directories examined per boot sweep: a bound on the file-system work one start-up can cause. */
export const SWEEP_LIMIT = 200;

export interface ReplyAssets {
  /**
   * Renders every Mermaid block of `replyText` and stores the files, then stages them with the store: no row, so nothing on
   * the wire, until `MemoStore.completeStep` commits this reply. A commit that wins replaces the rows of the earlier reply
   * and prunes its files; one that loses its compare-and-set leaves the earlier reply's rows and files alone and removes
   * only these new files (`reply.assets_discarded`). Never throws: a block that cannot be rendered (`reply.render_failed`)
   * or stored (`reply.store_failed`) stays a code block, a reply whose blocks all fail commits with the failed marker (the
   * backfill skips it), and a failure of the whole pass (`reply.assets_failed`, its new files removed) leaves the reply as
   * plain markdown.
   */
  sync(params: { memoId: string; replyText: string }): Promise<void>;
  /**
   * Renders the assets of older, committed replies that contain a Mermaid fence and have none: at most `limit` memos,
   * newest first, each serialized with the memo's other passes. Idempotent: a memo that has assets, or whose blocks all
   * failed to render (marked until its reply changes), is not a candidate. Never throws. Resolves with how many memos got assets.
   */
  backfill(params?: { limit?: number }): Promise<number>;
  /**
   * Removes the files under the asset directory that no `reply_assets` row names and no in-flight attempt has staged: what a
   * crash between a commit and its prune left behind, and files of a memo that no longer exists. At most `limit` memo
   * directories, most recently changed first, each inside the memo's queue (never between a render's write and its staging).
   * A file a row references is never touched. Logs what it removed (`reply.orphans_removed`). Never throws. Resolves with the
   * number of files removed.
   */
  sweep(params?: { limit?: number }): Promise<number>;
  /** Ends a running or future `backfill` or `sweep` after the memo it is on; `sync` is unaffected. Call before `idle()` at shutdown. */
  stop(): void;
  /** Resolves when the passes and discards that are running or queued have finished (shutdown drain). */
  idle(): Promise<void>;
}

export function createReplyAssets(deps: {
  store: MemoStore;
  assets: AssetStore;
  renderer: DiagramRenderer;
}): ReplyAssets {
  const { store, assets, renderer } = deps;
  // Passes for one memo run one after another: a later pass's prune must not delete the files an earlier one just stored.
  const perMemo = createKeyedQueue();
  const running = new Set<Promise<unknown>>();
  // Files an attempt has staged and the store has not settled yet: no row names them, they are not orphans.
  const holds = new Map<string, ReadonlySet<string>>();
  let stopped = false;
  const track = <T>(task: Promise<T>) => {
    running.add(task);
    const forget = () => running.delete(task);
    task.then(forget, forget);
    return task;
  };

  async function renderBlock(params: { memoId: string; block: number; source: string }) {
    const { memoId, block, source } = params;
    let rendered;
    try {
      rendered = await renderer.render(source);
    } catch (err) {
      log("reply.render_failed", { memo_id: memoId, block, error: String(err) });
      return { assets: [], rejected: true };
    }
    const { width, height } = rendered;
    const files: { asset: ReplyAsset; bytes: Uint8Array }[] = [];
    for (const scheme of ["light", "dark"] as const) {
      const { svg, png } = rendered[scheme];
      const common = { block, scheme, width, height };
      files.push(
        {
          asset: { id: crypto.randomUUID(), format: "svg", ...common },
          bytes: new TextEncoder().encode(svg),
        },
        { asset: { id: crypto.randomUUID(), format: "png", ...common }, bytes: png },
      );
    }
    try {
      for (const { asset, bytes } of files) {
        await assets.put({ memoId, assetId: asset.id, bytes });
      }
    } catch (err) {
      log("reply.store_failed", { memo_id: memoId, block, error: String(err) });
      await assets
        .remove({ memoId, assetIds: files.map((f) => f.asset.id) })
        .catch(() => undefined);
      return { assets: [], rejected: false };
    }
    return { assets: files.map((f) => f.asset), rejected: false };
  }

  /**
   * Renders and stores every block of the reply (capped); the files exist, nothing references them yet. `blocks` is how many
   * were tried, `rejected` how many the renderer refused (a block that failed to store is not one: that may pass next time).
   */
  async function renderReply(memoId: string, replyText: string) {
    const stored: ReplyAsset[] = [];
    let rejected = 0;
    const sources = extractMermaidBlocks(replyText);
    if (sources.length > MAX_BLOCKS) {
      log("reply.blocks_capped", { memo_id: memoId, total: sources.length, cap: MAX_BLOCKS });
    }
    for (const [block, source] of sources.slice(0, MAX_BLOCKS).entries()) {
      // Rendering is synchronous CPU work: let queued requests run between two blocks.
      await new Promise((resolve) => setImmediate(resolve));
      const result = await renderBlock({ memoId, block, source });
      stored.push(...result.assets);
      if (result.rejected) rejected++;
    }
    return { stored, blocks: Math.min(sources.length, MAX_BLOCKS), rejected };
  }

  /** Deletes every file of the memo that no row names. */
  async function pruneToRows(memoId: string) {
    const blocks = store.getMemo(memoId)?.replyBlocks ?? [];
    const keep = new Set(blocks.flatMap((b) => [b.svg.light, b.svg.dark, b.png.light, b.png.dark]));
    await assets.prune({ memoId, keep });
  }

  /** Drops a hold, unless a newer staging of the memo has replaced it already. */
  const release = (memoId: string, held: ReadonlySet<string>) => {
    if (holds.get(memoId) === held) holds.delete(memoId);
  };

  /** What follows the store settling a staged reply, inside the memo's queue. */
  function settled(params: {
    memoId: string;
    stored: readonly ReplyAsset[];
    failed: boolean;
    held: ReadonlySet<string>;
  }) {
    const { memoId, stored, failed, held } = params;
    return (outcome: "committed" | "discarded") => {
      release(memoId, held);
      if (outcome === "discarded") log("reply.assets_discarded", { memo_id: memoId });
      if (outcome === "committed" && failed) log("reply.assets_marked_failed", { memo_id: memoId });
      // Committed: the earlier reply's files are unreferenced now. Discarded: only this attempt's files go.
      const cleanup =
        outcome === "committed"
          ? () => pruneToRows(memoId)
          : () => assets.remove({ memoId, assetIds: stored.map((a) => a.id) });
      void track(perMemo(memoId, cleanup)).catch((err: unknown) =>
        log("reply.assets_failed", { memo_id: memoId, error: String(err) }),
      );
    };
  }

  async function run(memoId: string, replyText: string) {
    let stored: ReplyAsset[] = [];
    // Once the store holds them it settles them (committed or discarded): from then on they are not ours to delete.
    let staged = false;
    let held: ReadonlySet<string> | undefined;
    try {
      const rendered = await renderReply(memoId, replyText);
      stored = rendered.stored;
      // Marked only when the renderer refused every block: a failed store (a full disk) is worth another try at boot.
      const failed = rendered.blocks > 0 && rendered.rejected === rendered.blocks;
      // Held for as long as the store tracks the files: the boot sweep must not take them for orphans.
      const own = new Set(stored.map((a) => a.id));
      held = own;
      holds.set(memoId, own);
      // False for a memo purged while it rendered: no row is left to own the files.
      staged = store.stageReplyAssets(memoId, {
        replyText,
        assets: stored,
        failed,
        onSettled: settled({ memoId, stored, failed, held: own }),
      });
    } catch (err) {
      log("reply.assets_failed", { memo_id: memoId, error: String(err) });
    }
    if (!staged) {
      if (held) release(memoId, held);
      await assets.remove({ memoId, assetIds: stored.map((a) => a.id) }).catch(() => undefined);
    }
  }

  /** One memo of the backfill, inside its queue: the reply is read again, a retry or deletion in between wins. */
  async function backfillOne(memoId: string, replyText: string) {
    const stored: ReplyAsset[] = [];
    let attached = false;
    try {
      const memo = store.getMemo(memoId);
      if (!memo || memo.deletedAt !== null || memo.replyText !== replyText) return false;
      if (memo.replyBlocks.length > 0) return false;
      const rendered = await renderReply(memoId, replyText);
      stored.push(...rendered.stored);
      if (stored.length === 0) {
        // The renderer refused every diagram: remember it, or the next boot renders them all again.
        if (
          rendered.rejected === rendered.blocks &&
          store.markReplyAssetsFailed({ id: memoId, replyText })
        ) {
          log("reply.assets_marked_failed", { memo_id: memoId });
        }
        return false;
      }
      attached = store.attachReplyAssets({ id: memoId, replyText, assets: stored });
      return attached;
    } catch (err) {
      log("reply.assets_failed", { memo_id: memoId, error: String(err) });
      return false;
    } finally {
      if (!attached) {
        await assets.remove({ memoId, assetIds: stored.map((a) => a.id) }).catch(() => undefined);
      }
    }
  }

  /** One memo directory of the sweep, inside its queue: rows and holds are read after the queue reached it. */
  async function sweepOne(memoId: string) {
    const rows = store.getMemo(memoId)?.replyBlocks ?? [];
    const keep = new Set([
      ...rows.flatMap((b) => [b.svg.light, b.svg.dark, b.png.light, b.png.dark]),
      ...(holds.get(memoId) ?? []),
    ]);
    const orphans = (await assets.list(memoId)).filter((name) => !keep.has(name));
    if (orphans.length === 0) return 0;
    await assets.prune({ memoId, keep });
    log("reply.orphans_removed", { memo_id: memoId, count: orphans.length, files: orphans });
    return orphans.length;
  }

  async function sweep(limit: number) {
    let examined = 0;
    let removed = 0;
    let total = 0;
    try {
      const memoIds = await assets.listMemos();
      total = memoIds.length;
      for (const memoId of memoIds) {
        if (examined >= limit || stopped) break;
        examined++;
        try {
          removed += await perMemo(memoId, () => sweepOne(memoId));
        } catch (err) {
          log("reply.sweep_failed", { memo_id: memoId, error: String(err) });
        }
      }
    } catch (err) {
      log("reply.sweep_failed", { error: String(err) });
    }
    // `total - examined` directories were left for a later boot (or a stop): the limit is visible when it bites.
    log("reply.sweep", { examined, removed, skipped: total - examined });
    return removed;
  }

  async function backfill(limit: number) {
    let done = 0;
    let examined = 0;
    let beforeSeq: number | undefined;
    try {
      while (examined < limit && !stopped) {
        const page = store.listReplyAssetCandidates({ beforeSeq, limit: 100 });
        if (page.length === 0) break;
        for (const candidate of page) {
          beforeSeq = candidate.seq;
          // The query matches the word; only a real top-level fence is work (and counts against the bound).
          if (extractMermaidBlocks(candidate.replyText).length === 0) continue;
          if (examined >= limit || stopped) break;
          examined++;
          if (await perMemo(candidate.id, () => backfillOne(candidate.id, candidate.replyText))) {
            done++;
          }
        }
        if (page.length < 100) break;
      }
    } catch (err) {
      log("reply.backfill_failed", { error: String(err) });
    }
    log("reply.backfill", { examined, rendered: done });
    return done;
  }

  return {
    sync: ({ memoId, replyText }) => track(perMemo(memoId, () => run(memoId, replyText))),
    stop: () => {
      stopped = true;
    },
    backfill: ({ limit = BACKFILL_LIMIT } = {}) => track(backfill(limit)),
    sweep: ({ limit = SWEEP_LIMIT } = {}) => track(sweep(limit)),
    idle: async () => {
      while (running.size > 0) await Promise.allSettled(running);
    },
  };
}
