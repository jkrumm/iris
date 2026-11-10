import { describe, expect, it } from "bun:test";
import { Glob } from "bun";
import { readdirSync } from "node:fs";
import map from "./uitest-map.json";
import { select, type UiTestMap } from "./uitest-select";

const uiTestMap = map as UiTestMap;
const root = new URL("..", import.meta.url).pathname;
const tracked = Bun.spawnSync(["git", "ls-files", "--cached", "--others", "--exclude-standard"], {
  cwd: root,
})
  .stdout.toString()
  .split("\n")
  .filter(Boolean);
const uiTestSources = readdirSync(`${root}apple/Tests/UITests`).filter((name) =>
  name.endsWith(".swift"),
);
const declaredClasses = new Set(
  (
    await Promise.all(
      uiTestSources.map((name) => Bun.file(`${root}apple/Tests/UITests/${name}`).text()),
    )
  ).flatMap((text) =>
    [...text.matchAll(/^(?:final )?class (\w+UITests)\b/gm)].map((hit) => hit[1] ?? ""),
  ),
);
declaredClasses.delete("IrisUITestCase");

describe("select", () => {
  it("maps a screen's file to that screen's classes", () => {
    const { classes } = select(["apple/Iris/HistoryView.swift"], uiTestMap);
    expect(classes).toEqual(["HistorySwipeUITests", "SmokeUITests"]);
  });

  it("unions the classes of several files", () => {
    const { classes } = select(
      ["apple/Iris/ComposerView.swift", "apple/Iris/StatsView.swift"],
      uiTestMap,
    );
    expect(classes).toEqual(["CaptureUITests", "StatsSettingsUITests", "TypedMemoUITests"]);
  });

  it("falls back to the smoke class when nothing maps", () => {
    expect(select(["apple/IrisMac/MacSidebar.swift", "docs/x.md"], uiTestMap).classes).toEqual([
      "SmokeUITests",
    ]);
    expect(select([], uiTestMap).classes).toEqual(["SmokeUITests"]);
  });

  it("runs the whole suite when a file the suite sits on changes, whatever else changed", () => {
    expect(select(["apple/Iris/HistoryView.swift", "apple/project.yml"], uiTestMap).classes).toBe(
      "ALL",
    );
    expect(select(["apple/Tests/UITests/IrisUITestCase.swift"], uiTestMap).classes).toBe("ALL");
  });

  it("names why each file was picked", () => {
    const { reasons } = select(["apple/Iris/ThreadView.swift"], uiTestMap);
    expect(reasons).toEqual(["apple/Iris/ThreadView.swift: threads, replies, diagrams"]);
  });
});

describe("uitest-map.json", () => {
  const named = new Set([...uiTestMap.default, ...uiTestMap.rules.flatMap((rule) => rule.classes)]);

  it("names only classes that exist", () => {
    for (const name of named) expect(declaredClasses.has(name), name).toBe(true);
  });

  it("covers every UI test class, so none runs only nightly by accident", () => {
    for (const name of declaredClasses) expect(named.has(name), name).toBe(true);
  });

  it("has no pattern that matches nothing", () => {
    const patterns = [...uiTestMap.all, ...uiTestMap.rules.flatMap((rule) => rule.paths)];
    for (const pattern of patterns) {
      const glob = new Glob(pattern);
      expect(
        tracked.some((file) => glob.match(file)),
        pattern,
      ).toBe(true);
    }
  });
});
