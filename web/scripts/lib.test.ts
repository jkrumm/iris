import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertBudget, BUDGET_BYTES, gzipSizes, isSpikeFile } from "./lib";

test("only the spike's island files are spared by the sync", () => {
  for (const name of ["island.html", "island.css", "island.js"])
    expect(isSpikeFile(name)).toBe(true);
  for (const name of ["index.html", "artifact.js", "island.js.map", "KaTeX_Main-Regular.woff2"]) {
    expect(isSpikeFile(name)).toBe(false);
  }
});

test("woff2 counts as is, the rest gzipped, and the budget throws when exceeded", () => {
  const dir = mkdtempSync(join(tmpdir(), "iris-web-test-"));
  writeFileSync(join(dir, "a.js"), "x".repeat(10_000));
  writeFileSync(join(dir, "f.woff2"), "y".repeat(500));
  const sizes = gzipSizes(dir);
  expect(sizes["f.woff2"]).toBe(500);
  expect(sizes["a.js"]).toBeLessThan(200);
  expect(assertBudget(dir)).toBeLessThan(BUDGET_BYTES);
  writeFileSync(join(dir, "big.woff2"), Buffer.alloc(BUDGET_BYTES + 1));
  expect(() => assertBudget(dir)).toThrow(/budget/);
});
