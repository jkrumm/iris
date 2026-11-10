import { describe, expect, test } from "bun:test";
import { parsePayload } from "./payload";

const theme = { scheme: "light" };

describe("parsePayload", () => {
  test("accepts a show artifact", () => {
    const payload = parsePayload({ artifact: { kind: "show", spec: { any: 1 } }, theme });
    expect(payload?.artifact).toEqual({ kind: "show", spec: { any: 1 } });
    expect(payload?.theme).toEqual({ scheme: "light" });
  });

  test("accepts docs with and without a title, and theme vars", () => {
    const md = parsePayload({
      artifact: { kind: "doc", format: "markdown", content: "# Hi" },
      theme: { scheme: "dark", vars: { "--iris-bg": "red" } },
    });
    expect(md?.artifact).toEqual({ kind: "doc", format: "markdown", content: "# Hi" });
    expect(md?.theme.vars).toEqual({ "--iris-bg": "red" });
    const html = parsePayload({
      artifact: { kind: "doc", format: "html", title: "T", content: "<p>x</p>" },
      theme,
    });
    expect(html?.artifact).toEqual({
      kind: "doc",
      format: "html",
      title: "T",
      content: "<p>x</p>",
    });
  });

  test.each([
    ["null", null],
    ["a string", "payload"],
    ["an array", []],
    ["no theme", { artifact: { kind: "show", spec: {} } }],
    ["a bad scheme", { artifact: { kind: "show", spec: {} }, theme: { scheme: "sepia" } }],
    [
      "non-string vars",
      { artifact: { kind: "show", spec: {} }, theme: { scheme: "dark", vars: { a: 1 } } },
    ],
    [
      "vars not an object",
      { artifact: { kind: "show", spec: {} }, theme: { scheme: "dark", vars: [] } },
    ],
    ["no artifact", { theme }],
    ["a show without spec", { artifact: { kind: "show" }, theme }],
    ["an unknown kind", { artifact: { kind: "video" }, theme }],
    ["a bad doc format", { artifact: { kind: "doc", format: "pdf", content: "x" }, theme }],
    ["a doc without content", { artifact: { kind: "doc", format: "html" }, theme }],
    [
      "a non-string title",
      { artifact: { kind: "doc", format: "html", title: 3, content: "x" }, theme },
    ],
  ])("rejects %s", (_name, value) => {
    expect(parsePayload(value)).toBeNull();
  });
});
