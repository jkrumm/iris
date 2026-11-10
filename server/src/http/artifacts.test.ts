import { describe, expect, it } from "bun:test";
import { captureLogs, seedMemo } from "../memo/test-support.js";
import { createReplyAssets } from "../memo/reply-assets.js";
import { fakeAssetStore, fakeDiagramRenderer } from "../ports/fakes.js";
import { call, testApp } from "./test-support.js";

const fence = (info: string, body: string) => `\`\`\`${info}\n${body}\n\`\`\``;
const SPEC = { type: "callout", tone: "info", title: "Note", body: "Hello" };

async function withArtifacts() {
  const assets = fakeAssetStore();
  const h = testApp({ assets });
  const { id } = seedMemo(h.store, "acted");
  const replyText = [
    "Intro",
    fence("iris-show", JSON.stringify(SPEC)),
    fence("iris-show", '{"type":"table","columns":[]}'),
    fence('iris-doc title="Plan" format=markdown', "# Plan"),
    fence("iris-doc format=html", "<h1>Plan</h1>"),
  ].join("\n\n");
  const replies = createReplyAssets({ store: h.store, assets, renderer: fakeDiagramRenderer() });
  const { lines } = await captureLogs(async () => {
    await replies.sync({ memoId: id, replyText });
    h.store.completeStep({ id, step: "act", from: "acted", to: "acted", patch: { replyText } });
    await replies.idle();
  });
  const detail = async () =>
    (await call(h.app, { path: `/v1/memos/${id}` }).then((r) => r.json())) as {
      replyArtifacts?: {
        index: number;
        kind: string;
        title?: string;
        format?: string;
        assetId: string;
        bytes: number;
      }[];
    };
  const get = (assetId: string) => call(h.app, { path: `/v1/memos/${id}/assets/${assetId}` });
  return { id, lines, detail, get };
}

describe("reply artifacts on the wire", () => {
  it("lists exactly the valid artifacts and logs the invalid fence once", async () => {
    const { detail, lines, id } = await withArtifacts();
    const body = await detail();
    expect(body.replyArtifacts?.map((a) => [a.kind, a.index, a.title, a.format])).toEqual([
      ["show", 0, "Note", undefined],
      ["doc", 0, "Plan", "markdown"],
      ["doc", 1, undefined, "html"],
    ]);
    const invalid = lines.filter((l) => l["event"] === "reply.artifact_invalid");
    expect(invalid).toEqual([
      expect.objectContaining({ memo_id: id, kind: "show", index: 1, reason: "bad_spec" }),
    ]);
  });

  it("omits replyArtifacts when a reply has none", async () => {
    const h = testApp();
    const { id } = seedMemo(h.store, "notified");
    const body = (await call(h.app, { path: `/v1/memos/${id}` }).then((r) => r.json())) as object;
    expect("replyArtifacts" in body).toBe(false);
  });

  it("serves each artifact with its content type, and the sandbox CSP on html", async () => {
    const { detail, get } = await withArtifacts();
    const [spec, markdown, html] = (await detail()).replyArtifacts ?? [];

    const show = await get(spec?.assetId ?? "");
    expect([show.status, show.headers.get("content-type")]).toEqual([200, "application/json"]);
    expect(show.headers.get("x-content-type-options")).toBe("nosniff");
    expect(show.headers.get("content-security-policy")).toBeNull();
    expect(await show.json()).toEqual(SPEC);

    const md = await get(markdown?.assetId ?? "");
    expect(md.headers.get("content-type")).toBe("text/markdown; charset=utf-8");
    expect(md.headers.get("content-security-policy")).toBeNull();
    expect(await md.text()).toBe("# Plan");

    const page = await get(html?.assetId ?? "");
    expect(page.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(page.headers.get("content-security-policy")).toBe(
      "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:",
    );
    expect(page.headers.get("cache-control")).toContain("immutable");
  });
});
