import { describe, expect, it } from "bun:test";
import { t } from "elysia";
import { testApp } from "../http/test-support.js";
import { ListQuery } from "../http/schemas.js";
import { exportAll, exportSchema } from "./export.js";
import { CONTRACT_SCHEMAS } from "./registry.js";

const KEYWORDS_NEVER_EXPORTED = [
  "default",
  "nullable",
  "additionalProperties",
  "format",
  "multipleOf",
  "$id",
];

function keywordsIn(node: unknown, found: Set<string> = new Set()): Set<string> {
  if (Array.isArray(node)) node.forEach((child) => keywordsIn(child, found));
  else if (node && typeof node === "object") {
    for (const [key, child] of Object.entries(node)) {
      found.add(key);
      // `properties` maps names to schemas: its keys are field names, not keywords.
      if (key === "properties") {
        for (const schema of Object.values(child as object)) keywordsIn(schema, found);
      } else keywordsIn(child, found);
    }
  }
  return found;
}

describe("exportSchema", () => {
  it("writes draft 2020-12 with the contract name as title, sorted keys, 2 spaces, one newline", () => {
    const text = exportSchema({ name: "x.y", schema: t.Object({ b: t.String(), a: t.Number() }) });
    expect(text.endsWith("}\n")).toBe(true);
    expect(text.endsWith("\n\n")).toBe(false);
    expect(JSON.parse(text)).toEqual({
      $schema: "https://json-schema.org/draft/2020-12/schema",
      title: "x.y",
      type: "object",
      properties: { a: { type: "number" }, b: { type: "string" } },
      required: ["b", "a"],
    });
    expect(Object.keys(JSON.parse(text))).toEqual([
      "$schema",
      "properties",
      "required",
      "title",
      "type",
    ]);
    expect(text).toContain('\n  "title"');
  });

  it("strips enum defaults, normalises nullable, integers and Numeric", () => {
    const schema = t.Object({
      mode: t.UnionEnum(["a", "b"]),
      maybe: t.Nullable(t.String()),
      count: t.Number({ multipleOf: 1 }),
      limit: t.Optional(t.Numeric()),
    });
    const { properties } = JSON.parse(exportSchema({ name: "n", schema }));
    expect(properties.mode).toEqual({ type: "string", enum: ["a", "b"] });
    expect(properties.maybe).toEqual({ anyOf: [{ type: "string" }, { type: "null" }] });
    expect(properties.count).toEqual({ type: "integer" });
    expect(properties.limit).toEqual({ type: "number" });
  });

  it("is deterministic", () => {
    expect(Array.from(exportAll())).toEqual(Array.from(exportAll()));
    expect(exportSchema({ name: "q", schema: ListQuery })).toBe(
      exportSchema({ name: "q", schema: ListQuery }),
    );
  });
});

describe("exportAll", () => {
  it("emits one file per registered contract and no TypeBox-only keywords", () => {
    const all = exportAll();
    expect(Array.from(all.keys()).toSorted()).toEqual(
      Object.keys(CONTRACT_SCHEMAS)
        .map((name) => `${name}.json`)
        .toSorted(),
    );
    for (const [file, text] of all) {
      const found = keywordsIn(JSON.parse(text));
      for (const keyword of KEYWORDS_NEVER_EXPORTED) {
        expect([file, found.has(keyword)]).toEqual([file, false]);
      }
    }
  });
});

describe("exportAll after an app was built", () => {
  it("is unchanged by Elysia normalising the shared schemas in place", () => {
    const before = exportAll();
    testApp();
    expect(Array.from(exportAll())).toEqual(Array.from(before));
  });
});
