// Which XCUITest classes does a change need? `apple.yml` runs this on a push or pull request: the classes whose screens the changed
// files belong to (scripts/uitest-map.json), the smoke class when nothing maps, `ALL` when a file the whole suite sits on changed.
// The full suite runs nightly and on workflow_dispatch. stdout is the answer (`ALL` or space-separated class names), stderr the reasons.
//
//   bun scripts/uitest-select.ts --base <sha|ref> [--map scripts/uitest-map.json]
//
// A base that cannot be diffed (a rewritten history, a missing object) falls back to the last commit, then to ALL: an unknown change
// never runs less than a known one.
import { Glob } from "bun";

export interface UiTestRule {
  name: string;
  paths: string[];
  classes: string[];
}

export interface UiTestMap {
  default: string[];
  all: string[];
  rules: UiTestRule[];
}

export interface Selection {
  /** `ALL`, or the classes to run, sorted. */
  classes: "ALL" | string[];
  reasons: string[];
}

const matches = (patterns: string[], file: string): boolean =>
  patterns.some((pattern) => new Glob(pattern).match(file));

export function select(files: string[], map: UiTestMap): Selection {
  const reasons: string[] = [];
  const picked = new Set<string>();

  for (const file of files) {
    if (matches(map.all, file)) {
      reasons.push(`${file}: the whole suite sits on it -> ALL`);
      return { classes: "ALL", reasons };
    }
    const rules = map.rules.filter((rule) => matches(rule.paths, file));
    for (const rule of rules) for (const name of rule.classes) picked.add(name);
    if (rules.length > 0) reasons.push(`${file}: ${rules.map((rule) => rule.name).join("; ")}`);
  }

  if (picked.size > 0) return { classes: [...picked].toSorted(), reasons };

  reasons.push(
    files.length === 0
      ? "no changed file"
      : `no changed file maps to a UI test (${files.length} files) -> default`,
  );
  return { classes: [...map.default].toSorted(), reasons };
}

function git(args: string[]): string | null {
  const run = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  return run.exitCode === 0 ? run.stdout.toString() : null;
}

/** Files changed since `base`: the merge-base diff, then the last commit; null when neither works. */
export function changedFiles(base: string): string[] | null {
  const attempts = /^0+$/.test(base) || base === "" ? [] : [[`${base}...HEAD`], [base, "HEAD"]];
  for (const range of [...attempts, ["HEAD~1", "HEAD"]]) {
    const out = git(["diff", "--name-only", ...range]);
    if (out !== null) return out.split("\n").filter(Boolean);
  }
  return null;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const value = (flag: string) => {
    const at = args.indexOf(flag);
    return at === -1 ? undefined : args[at + 1];
  };
  const mapPath = value("--map") ?? new URL("./uitest-map.json", import.meta.url).pathname;
  const map = (await Bun.file(mapPath).json()) as UiTestMap;
  const files = changedFiles(value("--base") ?? "");

  if (files === null) {
    console.error("uitest subset: cannot diff against the base -> ALL");
    console.log("ALL");
  } else {
    const { classes, reasons } = select(files, map);
    for (const reason of reasons) console.error(`uitest subset: ${reason}`);
    console.error(
      `uitest subset: ${classes === "ALL" ? "the full suite" : classes.join(", ")} (${files.length} changed files)`,
    );
    console.log(classes === "ALL" ? "ALL" : classes.join(" "));
  }
}
