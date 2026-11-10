import { mkdtempSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

export const webDir = join(import.meta.dir, "..");
/** Where the app bundle reads the page from; island.{html,css,js} there belong to the spike and are never touched. */
export const resourceDir = join(
  webDir,
  "../apple/Packages/IrisUI/Sources/IrisUI/Resources/Artifact",
);
export const isSpikeFile = (name: string) => /^island\.(html|css|js)$/.test(name);

/** Total gzip budget (1.5 MB) for everything the build emits (sum of per-file gzip -9; woff2 counts as is). */
export const BUDGET_BYTES = 1_500_000;

/** A fresh production build in a temp dir; returns the dir. */
export async function buildToTemp(): Promise<string> {
  const out = mkdtempSync(join(tmpdir(), "iris-web-"));
  const build = Bun.spawn(["bun", "run", "build"], {
    cwd: webDir,
    env: { ...process.env, WEB_OUT: out },
    stdout: "ignore",
    stderr: "inherit",
  });
  if ((await build.exited) !== 0) throw new Error("vite build failed");
  return out;
}

export function gzipSizes(dir: string): Record<string, number> {
  const sizes: Record<string, number> = {};
  for (const name of readdirSync(dir).toSorted()) {
    if (!statSync(join(dir, name)).isFile()) continue;
    const bytes = readFileSync(join(dir, name));
    sizes[name] = name.endsWith(".woff2") ? bytes.length : gzipSync(bytes, { level: 9 }).length;
  }
  return sizes;
}

/** Throws above the budget; returns the total. */
export function assertBudget(dir: string): number {
  const sizes = gzipSizes(dir);
  const total = Object.values(sizes).reduce((sum, n) => sum + n, 0);
  const js = sizes["artifact.js"] ?? 0;
  const css = sizes["artifact.css"] ?? 0;
  const fonts = total - js - css - (sizes["index.html"] ?? 0);
  console.log(
    `bundle gzip: ${total} B total (js ${js}, css ${css}, fonts ${fonts}), budget ${BUDGET_BYTES}`,
  );
  if (total > BUDGET_BYTES)
    throw new Error(`bundle is ${total} B gzipped, over the ${BUDGET_BYTES} B budget`);
  return total;
}
