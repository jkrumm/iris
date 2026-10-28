import { describe, expect, it } from "bun:test";
import { fakeAssetStore, fakeDiagramRenderer } from "../ports/fakes.js";
import { MAX_BLOCKS, createReplyAssets, extractMermaidBlocks } from "./reply-assets.js";
import { captureLogs, seedMemo, testStore } from "./test-support.js";

const fence = (source: string, info = "mermaid") => `\`\`\`${info}\n${source}\n\`\`\``;

describe("extractMermaidBlocks", () => {
  it("returns every mermaid fence in order and ignores other fences", () => {
    const reply = [
      "Intro",
      fence("flowchart LR\n  A --> B"),
      fence("const x = 1;", "ts"),
      "between",
      fence('pie\n  "a" : 1', "Mermaid"),
    ].join("\n\n");
    expect(extractMermaidBlocks(reply)).toEqual(["flowchart LR\n  A --> B", 'pie\n  "a" : 1']);
  });

  it("accepts tilde fences, an indented fence, CRLF and extra info words", () => {
    expect(extractMermaidBlocks("~~~mermaid\nA-->B\n~~~")).toEqual(["A-->B"]);
    expect(extractMermaidBlocks("  ```mermaid title=x\nA-->B\n  ```")).toEqual(["A-->B"]);
    expect(extractMermaidBlocks("```mermaid\r\nA-->B\r\n```\r\n")).toEqual(["A-->B"]);
  });

  it("treats a mermaid fence nested in another fenced block as that block's text", () => {
    const reply = "````markdown\n```mermaid\nA-->B\n```\n````\n\n```mermaid\nC-->D\n```";
    expect(extractMermaidBlocks(reply)).toEqual(["C-->D"]);
  });

  it("closes only on a fence of the same character that is long enough and bare", () => {
    expect(extractMermaidBlocks("````mermaid\nA\n```\nB\n````")).toEqual(["A\n```\nB"]);
    expect(extractMermaidBlocks("```mermaid\nA\n~~~\nB\n```")).toEqual(["A\n~~~\nB"]);
    expect(extractMermaidBlocks("```mermaid\nA\n```ts\nB\n```")).toEqual(["A\n```ts\nB"]);
  });

  it("runs an unclosed fence to the end and skips inline backtick spans", () => {
    expect(extractMermaidBlocks("```mermaid\nA-->B")).toEqual(["A-->B"]);
    expect(extractMermaidBlocks("``` `mermaid`\nx\n```")).toEqual([]);
    expect(extractMermaidBlocks("no code here")).toEqual([]);
  });
});

function setup() {
  const { store } = testStore();
  const assets = fakeAssetStore();
  const renderer = fakeDiagramRenderer();
  const replies = createReplyAssets({ store, assets, renderer });
  const { id } = seedMemo(store, "acted");
  const blocks = () => store.getMemo(id)?.replyBlocks ?? [];
  return { store, assets, renderer, replies, id, blocks };
}

describe("sync", () => {
  it("renders each block to svg and png for light and dark, stores the files and references them per block", async () => {
    const { replies, assets, id, blocks, store } = setup();
    await replies.sync({ memoId: id, replyText: `${fence("A-->B")}\n\ntext\n\n${fence("C-->D")}` });

    expect(blocks().map((b) => [b.index, b.kind, b.width, b.height])).toEqual([
      [0, "mermaid", 120, 60],
      [1, "mermaid", 120, 60],
    ]);
    expect(assets.files.size).toBe(8);
    const [first] = blocks();
    const svgDark = await assets.read({ memoId: id, assetId: first?.svg.dark ?? "" });
    expect(new TextDecoder().decode(svgDark ?? new Uint8Array())).toContain('data-scheme="dark"');
    expect(store.getReplyAsset(id, first?.png.light ?? "")).toMatchObject({
      block: 0,
      format: "png",
      scheme: "light",
    });
  });

  it("leaves a block the renderer rejects as a code block: logged, no asset, the others still render", async () => {
    const { replies, id, blocks, assets } = setup();
    const { lines } = await captureLogs(() =>
      replies.sync({
        memoId: id,
        replyText: `${fence("A-->B")}\n${fence("unrenderable")}\n${fence("E-->F")}`,
      }),
    );
    expect(blocks().map((b) => b.index)).toEqual([0, 2]);
    expect(assets.files.size).toBe(8);
    expect(lines.filter((l) => l["event"] === "reply.render_failed")).toEqual([
      expect.objectContaining({ memo_id: id, block: 1 }),
    ]);
  });

  it("replaces the assets of an earlier reply: new ids, the old files gone", async () => {
    const { replies, id, blocks, assets } = setup();
    await replies.sync({ memoId: id, replyText: fence("A-->B") });
    const before = blocks();
    const oldFiles = [...assets.files.keys()];

    await replies.sync({ memoId: id, replyText: fence("X-->Y") });
    expect(blocks()).toHaveLength(1);
    expect(blocks()[0]?.svg.light).not.toBe(before[0]?.svg.light);
    expect(assets.files.size).toBe(4);
    for (const key of oldFiles) expect(assets.files.has(key)).toBe(false);

    await replies.sync({ memoId: id, replyText: "no diagram any more" });
    expect(blocks()).toEqual([]);
    expect(assets.files.size).toBe(0);
  });

  it("never throws: a failing store of the files costs the block (reply.store_failed) and leaves no file behind", async () => {
    const { store, renderer, id, blocks } = setup();
    const files = fakeAssetStore();
    let puts = 0;
    const broken = {
      ...files,
      put: async (params: Parameters<typeof files.put>[0]) => {
        // The block's first two files land, the third fails.
        if (++puts === 3) throw new Error("disk full");
        await files.put(params);
      },
    };
    const { lines } = await captureLogs(() =>
      createReplyAssets({ store, assets: broken, renderer }).sync({
        memoId: id,
        replyText: `${fence("A-->B")}\n${fence("C-->D")}`,
      }),
    );
    expect(blocks().map((b) => b.index)).toEqual([1]);
    expect(files.files.size).toBe(4);
    expect(lines.map((l) => [l["event"], l["block"]])).toEqual([["reply.store_failed", 0]]);
  });

  it("never throws: a failing database costs the whole pass, its new files are removed and the earlier reply survives", async () => {
    const { store, renderer, id, blocks, assets, replies } = setup();
    await replies.sync({ memoId: id, replyText: fence("A-->B") });
    const before = { files: [...assets.files.keys()], blocks: blocks() };

    const failingStore = {
      ...store,
      replaceReplyAssets: (): boolean => {
        throw new Error("db locked");
      },
    };
    const { lines } = await captureLogs(() =>
      createReplyAssets({ store: failingStore, assets, renderer }).sync({
        memoId: id,
        replyText: fence("X-->Y"),
      }),
    );
    expect(lines.map((l) => l["event"])).toEqual(["reply.assets_failed"]);
    expect([...assets.files.keys()]).toEqual(before.files);
    expect(blocks()).toEqual(before.blocks);
  });

  it("removes the files of a memo that was purged while its blocks rendered", async () => {
    const { replies, assets } = setup();
    await replies.sync({ memoId: crypto.randomUUID(), replyText: fence("A-->B") });
    expect(assets.files.size).toBe(0);
  });

  it("runs the passes of one memo one after another, so the last reply wins and no file is orphaned", async () => {
    const { replies, assets, id, blocks } = setup();
    await Promise.all([
      replies.sync({ memoId: id, replyText: `${fence("A-->B")}\n${fence("C-->D")}` }),
      replies.sync({ memoId: id, replyText: fence("E-->F") }),
    ]);
    expect(blocks()).toHaveLength(1);
    expect(assets.files.size).toBe(4);
    for (const asset of [blocks()[0]?.svg.light, blocks()[0]?.png.dark]) {
      expect(await assets.read({ memoId: id, assetId: asset ?? "" })).not.toBeNull();
    }
  });

  it(`renders at most ${MAX_BLOCKS} blocks and logs reply.blocks_capped`, async () => {
    const { replies, id, blocks } = setup();
    const reply = Array.from({ length: MAX_BLOCKS + 3 }, (_, i) => fence(`A${i}-->B`)).join("\n");
    const { lines } = await captureLogs(() => replies.sync({ memoId: id, replyText: reply }));
    expect(blocks()).toHaveLength(MAX_BLOCKS);
    expect(lines.filter((l) => l["event"] === "reply.blocks_capped")).toEqual([
      expect.objectContaining({ memo_id: id, total: MAX_BLOCKS + 3, cap: MAX_BLOCKS }),
    ]);
    expect(lines.some((l) => l["event"] === "reply.render_failed")).toBe(false);
  });
});
