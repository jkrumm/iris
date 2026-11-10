// `bun run build:check`: a fresh build must equal the committed bundle (minus island.*) and stay inside the size budget.
import { rmSync } from "node:fs";
import { assertBudget, buildToTemp, resourceDir } from "./lib";

const out = await buildToTemp();
try {
  assertBudget(out);
  const diff = Bun.spawnSync(["diff", "-r", "-x", "island.*", out, resourceDir], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (diff.exitCode !== 0) {
    console.error(diff.stdout.toString().slice(0, 2000));
    console.error(diff.stderr.toString().slice(0, 2000));
    console.error(
      "web bundle drift: the committed bundle differs from a fresh build. Run `make web-build` and commit the result.",
    );
    process.exit(1);
  }
  console.log("web bundle is up to date");
} finally {
  rmSync(out, { recursive: true, force: true });
}
