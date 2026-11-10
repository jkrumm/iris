import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parseSpec } from "./spec";

const fixtureDir = join(import.meta.dir, "../../contracts/fixtures");
const specFixtures = readdirSync(fixtureDir).filter((f) => f.startsWith("artifacts.show-spec."));

const chart = (over: object) => ({
  type: "chart",
  kind: "bar",
  x: ["a", "b"],
  series: [{ name: "s", values: [1, 2] }],
  ...over,
});

describe("parseSpec", () => {
  test("the contracts fixtures are all there", () => {
    expect(specFixtures.length).toBeGreaterThanOrEqual(8);
  });

  test.each(specFixtures)("%s is valid", (file) => {
    const value = JSON.parse(readFileSync(join(fixtureDir, file), "utf8"));
    expect(parseSpec(value)).not.toBeNull();
  });

  test.each([
    ["not an object", "table"],
    ["null", null],
    ["unknown type", { type: "gauge" }],
    ["unknown key", { type: "list", items: [{ text: "a" }], extra: 1 }],
    ["empty list", { type: "list", items: [] }],
    ["bad tone", { type: "callout", tone: "loud", body: "x" }],
    ["empty body", { type: "callout", tone: "info", body: "" }],
    ["title too long", { type: "list", title: "x".repeat(201), items: [{ text: "a" }] }],
    ["stat without items", { type: "stat" }],
    ["table row shorter than columns", { type: "table", columns: ["a", "b"], rows: [["x"]] }],
    ["table row longer than columns", { type: "table", columns: ["a"], rows: [["x", "y"]] }],
    ["object cell", { type: "table", columns: ["a"], rows: [[{}]] }],
    ["series shorter than x", chart({ series: [{ name: "s", values: [1] }] })],
    ["series longer than x", chart({ series: [{ name: "s", values: [1, 2, 3] }] })],
    [
      "second series off length",
      chart({
        series: [
          { name: "a", values: [1, 2] },
          { name: "b", values: [1] },
        ],
      }),
    ],
    [
      "pie with two series",
      chart({
        kind: "pie",
        series: [
          { name: "a", values: [1, 2] },
          { name: "b", values: [1, 2] },
        ],
      }),
    ],
    ["chart kind unknown", chart({ kind: "radar" })],
    ["string values", chart({ series: [{ name: "s", values: ["1", "2"] }] })],
  ])("rejects %s", (_name, value) => {
    expect(parseSpec(value)).toBeNull();
  });

  test("accepts a pie with one series and an empty table", () => {
    expect(parseSpec(chart({ kind: "pie" }))).not.toBeNull();
    expect(parseSpec({ type: "table", columns: ["a"], rows: [] })).not.toBeNull();
  });
});
