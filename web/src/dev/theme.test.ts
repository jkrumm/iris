import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { devVars } from "./theme";

const swift = readFileSync(
  join(
    import.meta.dir,
    "../../../apple/Packages/IrisUI/Sources/IrisUI/Components/Artifact/ArtifactTheme.swift",
  ),
  "utf8",
);
const hostNames = [...swift.matchAll(/"(--iris-[a-z0-9-]+)"/g)].map((m) => m[1]).toSorted();

test("the dev theme has exactly the variables the host emits", () => {
  expect(hostNames.length).toBeGreaterThan(30);
  expect(Object.keys(devVars("light")).toSorted()).toEqual(hostNames as string[]);
  expect(Object.keys(devVars("dark")).toSorted()).toEqual(hostNames as string[]);
});
