import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkContracts, SCHEMA_DIR } from "./check.js";
import { exportAll } from "./export.js";

// `bun run contracts:export` rewrites contracts/schema; `bun run contracts:check` verifies everything.

const root = join(import.meta.dir, "../../../contracts");
const command = process.argv[2];
const out = (line: string) => process.stdout.write(`${line}\n`);
const err = (line: string) => process.stderr.write(`${line}\n`);

if (command === "export") {
  const dir = join(root, SCHEMA_DIR);
  mkdirSync(dir, { recursive: true });
  for (const file of readdirSync(dir)) rmSync(join(dir, file));
  const schemas = exportAll();
  for (const [file, text] of schemas) writeFileSync(join(dir, file), text);
  out(`contracts: wrote ${schemas.size} schemas to contracts/${SCHEMA_DIR}`);
} else if (command === "check") {
  const problems = checkContracts({ root });
  for (const problem of problems) err(`contracts: ${problem}`);
  if (problems.length > 0) {
    err(`contracts: ${problems.length} problem(s)`);
    process.exit(1);
  }
  out("contracts: ok");
} else {
  err("usage: bun src/contracts/cli.ts export|check");
  process.exit(2);
}
