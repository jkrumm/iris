// `make web-build`: build into a temp dir, then replace the app bundle's page files (everything in the resource
// folder except the spike's island.*) with the build.
import { copyFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { assertBudget, buildToTemp, isSpikeFile, resourceDir } from "./lib";

const out = await buildToTemp();
try {
  assertBudget(out);
  mkdirSync(resourceDir, { recursive: true });
  for (const name of readdirSync(resourceDir)) {
    if (!isSpikeFile(name)) rmSync(join(resourceDir, name), { recursive: true, force: true });
  }
  for (const name of readdirSync(out)) copyFileSync(join(out, name), join(resourceDir, name));
  console.log(`synced ${readdirSync(out).length} files into ${resourceDir}`);
} finally {
  rmSync(out, { recursive: true, force: true });
}
