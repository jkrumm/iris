import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkContracts, schemaNameOfFixture } from "./check.js";
import { appRoutes } from "./routes.js";

const REAL_ROOT = join(import.meta.dir, "../../../contracts");
const routes = appRoutes();

describe("appRoutes", () => {
  it("enumerates the mounted routes without trailing slashes", () => {
    expect(routes).toContain("GET /health");
    expect(routes).toContain("POST /v1/memos");
    expect(routes).toContain("GET /v1/memos");
    expect(routes).toContain("PUT /v1/memos/:id/segments/:n");
    expect(routes).toContain("GET /v1/events");
    expect(routes.filter((r) => r.endsWith("/") && r.length > 1)).toEqual([]);
  });
});

describe("schemaNameOfFixture", () => {
  const names = new Set(["a.b.response", "error", "error.too-large"]);
  it("takes an exact name before a variant base", () => {
    expect(schemaNameOfFixture("error.too-large", names)).toBe("error.too-large");
    expect(schemaNameOfFixture("error.conflict", names)).toBe("error");
    expect(schemaNameOfFixture("a.b.response.failed", names)).toBe("a.b.response");
    expect(schemaNameOfFixture("a.b.respons", names)).toBeNull();
    expect(schemaNameOfFixture("nothing", names)).toBeNull();
  });
});

describe("checkContracts", () => {
  let root = "";
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "iris-contracts-"));
    cpSync(REAL_ROOT, root, { recursive: true });
  });
  afterEach(() => rmSync(root, { recursive: true, force: true }));

  const edit = (file: string, change: (text: string) => string) => {
    const path = join(root, file);
    writeFileSync(path, change(readFileSync(path, "utf8")));
  };
  const problems = () => checkContracts({ root, routes });

  it("is green on the committed contracts", () => {
    expect(problems()).toEqual([]);
  });

  it("fails when a schema field is renamed, naming the file and the fix", () => {
    edit("schema/liveactivity.content-state.json", (t) => t.replaceAll("hasReply", "hasAnswer"));
    const found = problems();
    expect(found).toContainEqual(
      expect.stringContaining(
        "schema/liveactivity.content-state.json: differs from the TypeBox export",
      ),
    );
    expect(found.join("\n")).toContain("make contracts");
    expect(found).toContainEqual(expect.stringContaining("fixtures/liveactivity.content-state"));
  });

  it("fails on a stale schema and on a missing one", () => {
    writeFileSync(join(root, "schema/ghost.json"), "{}\n");
    rmSync(join(root, "schema/whoami.response.json"));
    const found = problems();
    expect(found).toContainEqual(expect.stringContaining("schema/ghost.json: stale"));
    expect(found).toContainEqual(expect.stringContaining("schema/whoami.response.json: missing"));
  });

  it("fails when a fixture holds an invalid value", () => {
    edit("fixtures/memos.detail.response.failed.json", (t) =>
      t.replace('"state": "failed"', '"state": "exploded"'),
    );
    expect(problems()).toContainEqual(
      expect.stringContaining(
        "fixtures/memos.detail.response.failed.json: invalid against memos.detail.response",
      ),
    );
  });

  it("fails when a required field is missing, a type is wrong, or the fixture is not JSON", () => {
    edit("fixtures/whoami.response.json", () => "{}\n");
    edit("fixtures/health.response.json", (t) => t.replace('"inflight": 0', '"inflight": 0.5'));
    writeFileSync(join(root, "fixtures/error.json"), "{nope");
    const found = problems().join("\n");
    expect(found).toContain("fixtures/whoami.response.json: invalid");
    expect(found).toContain("fixtures/health.response.json: invalid");
    expect(found).toContain("fixtures/error.json: not valid JSON");
  });

  it("fails on a fixture that matches no schema and a schema without a fixture", () => {
    writeFileSync(join(root, "fixtures/nothing.like.this.json"), "{}\n");
    rmSync(join(root, "fixtures/herd.response.json"));
    rmSync(join(root, "fixtures/herd.response.empty.json"));
    const found = problems();
    expect(found).toContainEqual(
      expect.stringContaining("fixtures/nothing.like.this.json: no schema"),
    );
    expect(found).toContainEqual(
      expect.stringContaining("schema/herd.response.json: has no fixture"),
    );
  });

  it("fails when the manifest drops a route the app serves", () => {
    edit("manifest.json", (text) => {
      const manifest = JSON.parse(text);
      manifest.routes = manifest.routes.filter((r: { path: string }) => r.path !== "/v1/herd");
      return JSON.stringify(manifest);
    });
    const found = problems();
    expect(found).toContainEqual(
      expect.stringContaining("route GET /v1/herd exists but is not in the manifest"),
    );
    expect(found).toContainEqual(
      expect.stringContaining("schema herd.response is not referenced by any route"),
    );
  });

  it("fails when the manifest lists a route the app does not serve", () => {
    edit("manifest.json", (text) => {
      const manifest = JSON.parse(text);
      manifest.routes.push({
        method: "GET",
        path: "/v1/threads",
        auth: "bearer",
        responses: { "200": { mediaType: "application/json", schema: "whoami.response" } },
      });
      return JSON.stringify(manifest);
    });
    expect(problems()).toContainEqual(
      expect.stringContaining("lists GET /v1/threads, which the app does not serve"),
    );
  });

  it("fails on an unknown schema reference and on a malformed manifest", () => {
    edit("manifest.json", (t) => t.replace('"schema": "herd.response"', '"schema": "herd.nope"'));
    expect(problems()).toContainEqual(
      expect.stringContaining("references unknown schema herd.nope"),
    );

    writeFileSync(join(root, "manifest.json"), JSON.stringify({ routes: [] }));
    expect(problems().some((p) => p.startsWith("manifest.json:"))).toBe(true);
  });
});
