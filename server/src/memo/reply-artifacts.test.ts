import { describe, expect, it } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fakeAssetStore, fakeDiagramRenderer, fakeSpeechCache } from "../ports/fakes.js";
import {
  MAX_ARTIFACTS,
  MAX_DOC_BYTES,
  MAX_SHOW_BYTES,
  ShowSpec,
  artifactContentType,
  extractReplyArtifacts,
  parseDocInfo,
} from "./reply-artifacts.js";
import { PURGE_AFTER_MS } from "./memo.js";
import { createPurger } from "./purge.js";
import { createReplyAssets, extractFences } from "./reply-assets.js";
import {
  captureLogs,
  fakeAudio,
  markFailed,
  seedMemo,
  testStore,
  transition,
} from "./test-support.js";

const fence = (info: string, body: string) => `\`\`\`${info}\n${body}\n\`\`\``;
const show = (spec: unknown) => fence("iris-show", JSON.stringify(spec));
const decode = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

const TABLE = { type: "table", columns: ["a", "b"], rows: [[1, "x"]] };
const MEMO_ID = "memo-1";
const extract = (replyText: string) => extractReplyArtifacts({ memoId: MEMO_ID, replyText });

describe("extractFences", () => {
  it("returns lang (lower-cased first word), the rest of the info string and the source of every top-level fence", () => {
    const reply = [
      '```iris-doc title="Q3  plan" format=html',
      "<p>x</p>",
      "```",
      "",
      "~~~TS",
      "const x = 1;",
      "~~~",
    ].join("\n");
    expect(extractFences(reply)).toEqual([
      { lang: "iris-doc", info: 'title="Q3  plan" format=html', source: "<p>x</p>" },
      { lang: "ts", info: "", source: "const x = 1;" },
    ]);
  });
});

describe("ShowSpec", () => {
  const valid: Record<string, unknown> = {
    table: TABLE,
    "chart bar": {
      type: "chart",
      kind: "bar",
      x: ["a", 2],
      series: [{ name: "s", values: [1, null] }],
    },
    "chart pie": { type: "chart", kind: "pie", x: ["a"], series: [{ name: "s", values: [1] }] },
    stat: { type: "stat", items: [{ label: "l", value: 1, unit: "s", delta: -2, hint: "h" }] },
    list: { type: "list", ordered: true, items: [{ text: "t", detail: "d" }] },
    callout: { type: "callout", tone: "danger", title: "t", body: "b" },
  };

  for (const [name, spec] of Object.entries(valid)) {
    it(`accepts a ${name}`, () => {
      expect(ShowSpec.safeParse(spec).success).toBe(true);
    });
  }

  it("rejects unknown keys, ragged rows and series, a pie with two series and an over-long title", () => {
    const bad = [
      { ...TABLE, extra: 1 },
      { ...TABLE, rows: [[1]] },
      { ...TABLE, title: "x".repeat(201) },
      { ...TABLE, columns: [] },
      { type: "chart", kind: "line", x: [1, 2], series: [{ name: "s", values: [1] }] },
      {
        type: "chart",
        kind: "pie",
        x: [1],
        series: [
          { name: "a", values: [1] },
          { name: "b", values: [1] },
        ],
      },
      { type: "callout", tone: "loud", body: "b" },
      { type: "nope" },
    ];
    for (const spec of bad) expect(ShowSpec.safeParse(spec).success).toBe(false);
  });

  it("accepts every show fixture of the contract, so zod and the exported schema cannot drift", () => {
    const dir = join(import.meta.dir, "../../../contracts/fixtures");
    const files = readdirSync(dir).filter((f) => f.startsWith("artifacts.show-spec."));
    expect(files.length).toBeGreaterThanOrEqual(8);
    for (const file of files) {
      const parsed = ShowSpec.safeParse(JSON.parse(readFileSync(join(dir, file), "utf8")));
      expect([file, parsed.success]).toEqual([file, true]);
    }
  });
});

describe("parseDocInfo", () => {
  it("defaults to markdown and reads quoted and bare values", () => {
    expect(parseDocInfo("")).toEqual({ title: null, format: "markdown" });
    expect(parseDocInfo('title="Q3 plan" format=html')).toEqual({
      title: "Q3 plan",
      format: "html",
    });
    expect(parseDocInfo("title=Plan")).toEqual({ title: "Plan", format: "markdown" });
  });

  it("refuses an unknown key or format, a repeated key, an empty or long title and malformed pairs", () => {
    for (const info of [
      "color=red",
      "format=pdf",
      "format=html format=html",
      'title=""',
      `title="${"x".repeat(201)}"`,
      'title="open',
      'title="a"b',
      "title",
      "=x",
    ]) {
      expect([info, parseDocInfo(info)]).toEqual([info, null]);
    }
  });
});

describe("artifactContentType", () => {
  it("maps kind and format", () => {
    expect(artifactContentType({ kind: "show", format: null })).toBe("application/json");
    expect(artifactContentType({ kind: "doc", format: "markdown" })).toBe(
      "text/markdown; charset=utf-8",
    );
    expect(artifactContentType({ kind: "doc", format: "html" })).toBe("text/html; charset=utf-8");
  });
});

describe("extractReplyArtifacts", () => {
  it("stores a show spec as normalised JSON and a doc as its body, with titles from the spec and the info string", async () => {
    const { result, lines } = await captureLogs(async () =>
      extract(
        [
          show({ ...TABLE, title: "T" }),
          fence('iris-doc title="Plan" format=html', "<h1>Hi</h1>\n"),
          fence("iris-doc", "# md"),
        ].join("\n\n"),
      ),
    );
    expect(lines).toEqual([]);
    expect(result.map((a) => [a.kind, a.index, a.title, a.format])).toEqual([
      ["show", 0, "T", null],
      ["doc", 0, "Plan", "html"],
      ["doc", 1, null, "markdown"],
    ]);
    expect(JSON.parse(decode(result[0]?.bytes ?? new Uint8Array()))).toEqual({
      ...TABLE,
      title: "T",
    });
    expect(decode(result[1]?.bytes ?? new Uint8Array())).toBe("<h1>Hi</h1>\n");
  });

  it("logs each refusal reason without content and keeps the fence a code block", async () => {
    const reply = [
      fence("iris-show", "x".repeat(MAX_SHOW_BYTES + 1)),
      fence("iris-show", "{not json"),
      show({ ...TABLE, rows: [[1]], secret: "do-not-log" }),
      fence("iris-doc color=red", "body"),
      fence("iris-doc", "  \n "),
      fence("iris-doc", "x".repeat(MAX_DOC_BYTES + 1)),
    ].join("\n\n");
    const { result, lines } = await captureLogs(async () => extract(reply));
    expect(result).toEqual([]);
    const invalid = lines.filter((l) => l["event"] === "reply.artifact_invalid");
    expect(invalid.map((l) => [l["kind"], l["index"], l["reason"]])).toEqual([
      ["show", 0, "too_large"],
      ["show", 1, "bad_json"],
      ["show", 2, "bad_spec"],
      ["doc", 0, "bad_info"],
      ["doc", 1, "empty"],
      ["doc", 2, "too_large"],
    ]);
    expect(invalid.every((l) => l["memo_id"] === MEMO_ID)).toBe(true);
    const spec = invalid[2];
    expect(spec?.["issues"]).toEqual(
      expect.arrayContaining([
        { path: "rows.0", code: "custom" },
        { path: "", code: "unrecognized_keys" },
      ]),
    );
    expect(JSON.stringify(lines)).not.toContain("do-not-log");
  });

  it("counts the index among the fences of its kind, invalid ones included", async () => {
    const reply = [show({ type: "bad" }), fence("iris-doc", "ok"), show(TABLE)].join("\n\n");
    const { result } = await captureLogs(async () => extract(reply));
    expect(result.map((a) => [a.kind, a.index])).toEqual([
      ["show", 1],
      ["doc", 0],
    ]);
  });

  it(`takes at most ${MAX_ARTIFACTS} per kind and logs reply.artifacts_capped`, async () => {
    const reply = Array.from({ length: MAX_ARTIFACTS + 3 }, () => show(TABLE)).join("\n\n");
    const { result, lines } = await captureLogs(async () => extract(reply));
    expect(result).toHaveLength(MAX_ARTIFACTS);
    expect(lines).toEqual([
      expect.objectContaining({
        event: "reply.artifacts_capped",
        memo_id: MEMO_ID,
        kind: "show",
        total: MAX_ARTIFACTS + 3,
        cap: MAX_ARTIFACTS,
      }),
    ]);
  });

  it("ignores a fence nested in another fenced block and the iris routing block", async () => {
    const nested = `\`\`\`\`markdown\n${show(TABLE)}\n\`\`\`\``;
    const routing = fence("iris", '{"kind":"note","headline":"h"}');
    const { result, lines } = await captureLogs(async () => extract(`${nested}\n\n${routing}`));
    expect(result).toEqual([]);
    expect(lines).toEqual([]);
  });
});

function setup() {
  const { store, db, clock } = testStore();
  const assets = fakeAssetStore();
  const replies = createReplyAssets({ store, assets, renderer: fakeDiagramRenderer() });
  const { id } = seedMemo(store, "acted");
  const artifacts = () => store.getMemo(id)?.replyArtifacts ?? [];
  const render = async (replyText: string) => {
    await replies.sync({ memoId: id, replyText });
    store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
    await replies.idle();
  };
  return { store, db, clock, assets, replies, id, artifacts, render };
}

describe("artifact lifecycle", () => {
  it("commits the artifacts with the reply, invisible until then, kind then index", async () => {
    const { store, id, replies, artifacts, assets } = setup();
    const replyText = [fence("iris-doc title=D", "# d"), show(TABLE)].join("\n\n");
    await replies.sync({ memoId: id, replyText });
    expect(artifacts()).toEqual([]);
    store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
    await replies.idle();
    expect(artifacts().map((a) => [a.kind, a.index, a.title, a.format])).toEqual([
      ["show", 0, null, null],
      ["doc", 0, "D", "markdown"],
    ]);
    expect(assets.files.size).toBe(2);
    const doc = artifacts()[1];
    expect(store.getReplyArtifact(id, doc?.id ?? "")).toEqual(doc ?? null);
    expect(doc?.bytes).toBe(3);
  });

  it("drops one artifact whose file cannot be stored (reply.store_failed) and keeps the rest", async () => {
    const { store, id, artifacts } = setup();
    const files = fakeAssetStore();
    let puts = 0;
    const flaky = {
      ...files,
      put: async (params: Parameters<typeof files.put>[0]) => {
        if (++puts === 1) throw new Error("disk full");
        await files.put(params);
      },
    };
    const replies = createReplyAssets({ store, assets: flaky, renderer: fakeDiagramRenderer() });
    const replyText = [show(TABLE), fence("iris-doc", "ok")].join("\n\n");
    const { lines } = await captureLogs(async () => {
      await replies.sync({ memoId: id, replyText });
      store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
      await replies.idle();
    });
    expect(artifacts().map((a) => a.kind)).toEqual(["doc"]);
    expect(files.files.size).toBe(1);
    expect(lines.find((l) => l["event"] === "reply.store_failed")).toMatchObject({
      memo_id: id,
      kind: "show",
      index: 0,
    });
  });

  it("a retry from act with another reply prunes the old artifact files and the new ones are served", async () => {
    const { store, id, render, artifacts, assets } = setup();
    await render(show(TABLE));
    const old = artifacts().map((a) => a.id);
    expect(old).toHaveLength(1);

    markFailed(store, { id, step: "act", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(artifacts()).toEqual([]);
    transition(store, { id, from: "transcribed", to: "acted" });
    await render(fence("iris-doc", "new"));
    const fresh = artifacts().map((a) => a.id);
    expect(fresh).toHaveLength(1);
    expect(fresh).not.toEqual(old);
    expect([...assets.files.keys()].map((k) => k.split("/").at(-1))).toEqual(fresh);
    expect(await assets.read({ memoId: id, assetId: old[0] ?? "" })).toBeNull();
  });

  it("the purge removes the artifact rows and files", async () => {
    const { store, db, clock, id, render, assets } = setup();
    await render(show(TABLE));
    store.markDeleted({ id, at: clock.now().toISOString() });
    clock.advance(PURGE_AFTER_MS);
    const purger = createPurger({
      store,
      audio: fakeAudio(),
      speechCache: fakeSpeechCache(),
      assets,
      clock,
    });
    expect(await purger.sweep()).toEqual([id]);
    expect(assets.files.size).toBe(0);
    expect(db.query("SELECT * FROM reply_artifacts WHERE memo_id = ?").all(id)).toEqual([]);
  });

  it("the sweep keeps committed and held artifact files and removes orphans", async () => {
    const { replies, assets, id, store, artifacts } = setup();
    const replyText = show(TABLE);
    await replies.sync({ memoId: id, replyText });
    const held = [...assets.files.keys()].map((k) => k.split("/").at(-1) ?? "");
    // Staged and not yet committed: held, not an orphan.
    expect(await replies.sweep()).toBe(0);
    expect(assets.files.size).toBe(1);

    store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
    await replies.idle();
    await assets.put({ memoId: id, assetId: "orphan", bytes: new Uint8Array([1]) });
    expect(await replies.sweep()).toBe(1);
    expect(artifacts().map((a) => a.id)).toEqual(held);
    expect(assets.files.size).toBe(1);
  });

  it("the boot backfill leaves artifacts alone: a committed reply without them gets none", async () => {
    const { store, id, replies, artifacts, assets } = setup();
    const replyText = `${show(TABLE)}\n\n\`\`\`mermaid\nA-->B\n\`\`\``;
    store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
    expect(await replies.backfill()).toBe(1);
    expect(artifacts()).toEqual([]);
    expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);
    expect(assets.files.size).toBe(4);
  });
});
