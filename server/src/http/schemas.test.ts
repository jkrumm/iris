import { describe, expect, it } from "bun:test";
import * as schemas from "./schemas.js";

// The next worker exports these to JSON Schema, so no node may carry a Transform or a codec.
// `t.Numeric` (query strings) is the one deliberate exception, listed here.
const QUERY_SCHEMAS = new Set(["ListQuery", "ResultQuery", "ThreadListQuery"]);

function transformPaths(node: unknown, path: string): string[] {
  if (node === null || typeof node !== "object") return [];
  const here = Reflect.ownKeys(node).some(
    (key) => typeof key === "symbol" && key.description === "TypeBox.Transform",
  )
    ? [path]
    : [];
  return [
    ...here,
    ...Object.entries(node).flatMap(([key, child]) => transformPaths(child, `${path}.${key}`)),
  ];
}

describe("schemas", () => {
  it("exports the schemas the contracts need", () => {
    for (const name of [
      "Memo",
      "MemoDetail",
      "MemoList",
      "CreateMemoBody",
      "CreateTextMemoBody",
      "CompleteBody",
      "RetryBody",
      "ResultQuery",
      "RegisterDeviceBody",
      "Device",
      "ActivityTokenBody",
      "Thread",
      "ThreadList",
      "ThreadDetail",
      "ThreadListQuery",
      "HerdResponse",
      "ErrorBody",
      "MissingSegmentsError",
      "MemoEventPayload",
      "HealthResponse",
      "WhoamiResponse",
    ]) {
      expect(schemas).toHaveProperty(name);
    }
  });

  it("contain no Transform outside the query schemas, and serialize to plain JSON Schema", () => {
    for (const [name, schema] of Object.entries(schemas)) {
      if (QUERY_SCHEMAS.has(name)) continue;
      expect(transformPaths(schema, name)).toEqual([]);
      expect(JSON.parse(JSON.stringify(schema))).toMatchObject({ type: expect.any(String) });
    }
  });
});
