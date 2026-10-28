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

export interface ReplyAssets {
  /**
   * Makes the memo's stored assets match `replyText`: every Mermaid block is rendered and stored, the assets of an earlier
   * reply are removed. Never throws: a block that cannot be rendered (`reply.render_failed`) or stored (`reply.store_failed`)
   * stays a code block, and a failure of the whole pass (`reply.assets_failed`, its new files removed) leaves the reply as
   * plain markdown.
   */
  sync(params: { memoId: string; replyText: string }): Promise<void>;
}

export function createReplyAssets(deps: {
  store: MemoStore;
  assets: AssetStore;
  renderer: DiagramRenderer;
}): ReplyAssets {
  const { store, assets, renderer } = deps;
  // Passes for one memo run one after another: a later pass's prune must not delete the files an earlier one just stored.
  const perMemo = createKeyedQueue();

  async function renderBlock(params: { memoId: string; block: number; source: string }) {
    const { memoId, block, source } = params;
    let rendered;
    try {
      rendered = await renderer.render(source);
    } catch (err) {
      log("reply.render_failed", { memo_id: memoId, block, error: String(err) });
      return [];
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
      return [];
    }
    return files.map((f) => f.asset);
  }

  async function run(memoId: string, replyText: string) {
    const stored: ReplyAsset[] = [];
    // Once the rows name the new files they own them: from then on nothing may delete them as leftovers.
    let committed = false;
    try {
      const sources = extractMermaidBlocks(replyText);
      if (sources.length > MAX_BLOCKS) {
        log("reply.blocks_capped", { memo_id: memoId, total: sources.length, cap: MAX_BLOCKS });
      }
      for (const [block, source] of sources.slice(0, MAX_BLOCKS).entries()) {
        // Rendering is synchronous CPU work: let queued requests run between two blocks.
        await new Promise((resolve) => setImmediate(resolve));
        stored.push(...(await renderBlock({ memoId, block, source })));
      }
      // A memo purged while it rendered has no row left to own the files.
      committed = store.replaceReplyAssets(memoId, stored);
      await assets.prune({
        memoId,
        keep: new Set(committed ? stored.map((a) => a.id) : []),
      });
    } catch (err) {
      log("reply.assets_failed", { memo_id: memoId, error: String(err) });
      if (!committed) {
        await assets.remove({ memoId, assetIds: stored.map((a) => a.id) }).catch(() => undefined);
      }
    }
  }

  return {
    sync: ({ memoId, replyText }) => perMemo(memoId, () => run(memoId, replyText)),
  };
}
