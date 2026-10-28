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
   * reply are removed. Never throws: a block that cannot be rendered or stored stays a code block (`reply.render_failed`),
   * and a failure of the whole pass (`reply.assets_failed`) leaves the reply as plain markdown.
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
    try {
      const rendered = await renderer.render(source);
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
      for (const { asset, bytes } of files) {
        await assets.put({ memoId, assetId: asset.id, bytes });
      }
      return files.map((f) => f.asset);
    } catch (err) {
      log("reply.render_failed", { memo_id: memoId, block, error: String(err) });
      return [];
    }
  }

  async function run(memoId: string, replyText: string) {
    try {
      const sources = extractMermaidBlocks(replyText);
      if (sources.length > MAX_BLOCKS) {
        log("reply.render_failed", {
          memo_id: memoId,
          block: MAX_BLOCKS,
          error: `${sources.length} mermaid blocks, only the first ${MAX_BLOCKS} are rendered`,
        });
      }
      const stored: ReplyAsset[] = [];
      for (const [block, source] of sources.slice(0, MAX_BLOCKS).entries()) {
        // Rendering is synchronous CPU work: let queued requests run between two blocks.
        await new Promise((resolve) => setImmediate(resolve));
        stored.push(...(await renderBlock({ memoId, block, source })));
      }
      // A memo purged while it rendered has no row left to own the files.
      const kept = store.replaceReplyAssets(memoId, stored) ? stored : [];
      await assets.prune({ memoId, keep: new Set(kept.map((a) => a.id)) });
    } catch (err) {
      log("reply.assets_failed", { memo_id: memoId, error: String(err) });
    }
  }

  return {
    sync: ({ memoId, replyText }) => perMemo(memoId, () => run(memoId, replyText)),
  };
}
