import type { TSchema } from "elysia";
import { CONTRACT_SCHEMAS } from "./registry.js";

const DRAFT_2020_12 = "https://json-schema.org/draft/2020-12/schema";

type Node = Record<string, unknown>;

const isNode = (value: unknown): value is Node =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** `t.Numeric` (query strings): a numeric-string branch plus a number branch. Clients send numbers. */
const isNumericUnion = (node: Node) =>
  Array.isArray(node["anyOf"]) &&
  node["anyOf"].some((branch) => isNode(branch) && branch["format"] === "numeric");

/**
 * TypeBox → plain JSON Schema. Drops what TypeBox adds that would mislead a decoder or a codegen:
 * the `default` that `t.UnionEnum` and `t.Numeric` emit, OpenAPI-3.0 `nullable` (the `anyOf` with
 * `{type: "null"}` already says it), and `multipleOf: 1` (written as `integer`). Also
 * `additionalProperties: false`: Elysia writes it into the shared schema objects in place when a
 * route is composed (response normalisation), so whether it is present depends on whether an app
 * was built first. Contracts stay open for clients to ignore new fields; a schema that must be
 * empty says `maxProperties: 0`.
 */
function normalize(node: Node): Node {
  if (isNumericUnion(node)) return { type: "number" };
  const integer = node["type"] === "number" && node["multipleOf"] === 1;
  const out: Node = {};
  for (const [key, value] of Object.entries(node)) {
    if (key === "default" || key === "nullable" || key === "additionalProperties") continue;
    if (integer && key === "multipleOf") continue;
    if (key === "type" && integer) out[key] = "integer";
    else if (key === "properties" && isNode(value)) {
      out[key] = Object.fromEntries(
        Object.entries(value).map(([name, child]) => [name, normalize(child as Node)]),
      );
    } else if (key === "anyOf" && Array.isArray(value)) {
      out[key] = value.map((branch) => normalize(branch as Node));
    } else if (key === "items" && isNode(value)) out[key] = normalize(value);
    else out[key] = value;
  }
  return out;
}

/** Sorted keys at every depth; arrays keep their order. */
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (!isNode(value)) return value;
  return Object.fromEntries(
    Object.keys(value)
      .toSorted()
      .map((key) => [key, sortKeys(value[key])]),
  );
}

/** The bytes of `contracts/schema/<name>.json`: draft 2020-12, `title` = name, sorted keys, 2 spaces, newline. */
export function exportSchema(params: { name: string; schema: TSchema }): string {
  const plain = JSON.parse(JSON.stringify(params.schema)) as Node;
  const document = { $schema: DRAFT_2020_12, title: params.name, ...normalize(plain) };
  return `${JSON.stringify(sortKeys(document), null, 2)}\n`;
}

/** Schema file name → exact file content, for every registered contract. */
export function exportAll(): Map<string, string> {
  return new Map(
    Object.entries(CONTRACT_SCHEMAS).map(([name, schema]) => [
      `${name}.json`,
      exportSchema({ name, schema }),
    ]),
  );
}
