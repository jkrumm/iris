import Ajv2020, { type ValidateFunction } from "ajv/dist/2020";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { exportAll } from "./export.js";
import { Manifest, referencedSchemas, routeKey } from "./manifest.js";
import { appRoutes } from "./routes.js";

export const SCHEMA_DIR = "schema";
export const FIXTURE_DIR = "fixtures";
export const MANIFEST_FILE = "manifest.json";
const HINT = "run `make contracts`, review the diff, update the fixtures";

const jsonFiles = (dir: string) =>
  existsSync(dir)
    ? readdirSync(dir)
        .filter((file) => file.endsWith(".json"))
        .toSorted()
    : [];

/** Fixture stem → schema name: the stem itself, or the stem without its `.<variant>` suffix. */
export function schemaNameOfFixture(stem: string, schemaNames: ReadonlySet<string>): string | null {
  if (schemaNames.has(stem)) return stem;
  const base = stem.slice(0, Math.max(stem.lastIndexOf("."), 0));
  return schemaNames.has(base) ? base : null;
}

export interface Fixture {
  /** File stem, e.g. `memos.detail.response.failed`. */
  stem: string;
  /** Schema name it must validate against; null when the name matches none. */
  schema: string | null;
  value: unknown;
}

/** The on-disk contracts, loaded once: schema validators, fixtures, and parse problems. */
export function loadContracts(root: string) {
  const problems: string[] = [];
  const ajv = new Ajv2020({ strict: true, allErrors: true });

  const schemaFiles = jsonFiles(join(root, SCHEMA_DIR));
  const validators = new Map<string, ValidateFunction>();
  for (const file of schemaFiles) {
    const name = file.slice(0, -".json".length);
    try {
      const schema = JSON.parse(readFileSync(join(root, SCHEMA_DIR, file), "utf8")) as object;
      validators.set(name, ajv.compile(schema));
    } catch (err) {
      problems.push(`${SCHEMA_DIR}/${file}: does not compile (${(err as Error).message})`);
    }
  }

  const names = new Set(schemaFiles.map((file) => file.slice(0, -".json".length)));
  const fixtures: Fixture[] = [];
  for (const file of jsonFiles(join(root, FIXTURE_DIR))) {
    const stem = file.slice(0, -".json".length);
    try {
      const value: unknown = JSON.parse(readFileSync(join(root, FIXTURE_DIR, file), "utf8"));
      fixtures.push({ stem, schema: schemaNameOfFixture(stem, names), value });
    } catch (err) {
      problems.push(`${FIXTURE_DIR}/${file}: not valid JSON (${(err as Error).message})`);
    }
  }
  return { problems, validators, fixtures };
}

/** `[]` when `value` satisfies the schema, else one line per violation. */
export function violations(validate: ValidateFunction, value: unknown): string[] {
  if (validate(value)) return [];
  return (validate.errors ?? []).map(
    (error) => `${error.instancePath || "/"} ${error.message ?? "invalid"}`,
  );
}

function firstDifference(expected: string, actual: string): string {
  const want = expected.split("\n");
  const have = actual.split("\n");
  const line = want.findIndex((text, i) => text !== have[i]);
  const at = line === -1 ? want.length : line;
  return `line ${at + 1}: expected ${JSON.stringify(want[at] ?? "<end>")}, found ${JSON.stringify(have[at] ?? "<end>")}`;
}

function checkSchemaFiles(root: string): string[] {
  const expected = exportAll();
  const actual = new Set(jsonFiles(join(root, SCHEMA_DIR)));
  const problems: string[] = [];
  for (const [file, text] of expected) {
    if (!actual.has(file)) {
      problems.push(`${SCHEMA_DIR}/${file}: missing (${HINT})`);
      continue;
    }
    const found = readFileSync(join(root, SCHEMA_DIR, file), "utf8");
    if (found !== text) {
      problems.push(
        `${SCHEMA_DIR}/${file}: differs from the TypeBox export, ${firstDifference(text, found)} (${HINT})`,
      );
    }
  }
  for (const file of actual) {
    if (!expected.has(file))
      problems.push(`${SCHEMA_DIR}/${file}: stale, no such schema (${HINT})`);
  }
  return problems;
}

function checkFixtures(params: {
  root: string;
  fixtures: Fixture[];
  validators: Map<string, ValidateFunction>;
}) {
  const { fixtures, validators } = params;
  const problems: string[] = [];
  const covered = new Set<string>();
  for (const { stem, schema, value } of fixtures) {
    const validate = schema ? validators.get(schema) : undefined;
    if (!schema || !validate) {
      problems.push(`${FIXTURE_DIR}/${stem}.json: no schema named ${stem} (or its variant base)`);
      continue;
    }
    covered.add(schema);
    for (const message of violations(validate, value)) {
      problems.push(`${FIXTURE_DIR}/${stem}.json: invalid against ${schema}: ${message}`);
    }
  }
  for (const name of validators.keys()) {
    if (!covered.has(name)) problems.push(`${SCHEMA_DIR}/${name}.json: has no fixture`);
  }
  return problems;
}

function checkManifest(params: { root: string; routes: string[] }): string[] {
  const { root, routes } = params;
  const file = join(root, MANIFEST_FILE);
  if (!existsSync(file)) return [`${MANIFEST_FILE}: missing`];

  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(file, "utf8"));
  } catch (err) {
    return [`${MANIFEST_FILE}: not valid JSON (${(err as Error).message})`];
  }
  const parsed = Manifest.safeParse(raw);
  if (!parsed.success) {
    return parsed.error.issues.map((i) => `${MANIFEST_FILE}: ${i.path.join(".")}: ${i.message}`);
  }

  const problems: string[] = [];
  const listed = parsed.data.routes.map(routeKey);
  for (const key of new Set(listed.filter((k, i) => listed.indexOf(k) !== i))) {
    problems.push(`${MANIFEST_FILE}: ${key} is listed twice`);
  }
  for (const key of routes) {
    if (!listed.includes(key))
      problems.push(`${MANIFEST_FILE}: route ${key} exists but is not in the manifest`);
  }
  for (const key of new Set(listed)) {
    if (!routes.includes(key))
      problems.push(`${MANIFEST_FILE}: lists ${key}, which the app does not serve`);
  }

  const known = new Set(Array.from(exportAll().keys(), (f) => f.slice(0, -".json".length)));
  const referenced = referencedSchemas(parsed.data);
  for (const name of referenced) {
    if (!known.has(name)) problems.push(`${MANIFEST_FILE}: references unknown schema ${name}`);
  }
  for (const name of known) {
    if (!referenced.has(name))
      problems.push(`${MANIFEST_FILE}: schema ${name} is not referenced by any route`);
  }
  return problems;
}

/**
 * Every way `contracts/` can disagree with the code, one line each; `[]` is green. `routes`
 * defaults to the real app's route table.
 */
export function checkContracts(params: { root: string; routes?: string[] }): string[] {
  const { root, routes = appRoutes() } = params;
  const { problems, validators, fixtures } = loadContracts(root);
  return [
    ...checkSchemaFiles(root),
    ...problems,
    ...checkFixtures({ root, fixtures, validators }),
    ...checkManifest({ root, routes }),
  ];
}
