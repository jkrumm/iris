import { describe, expect, it } from "bun:test";
import { loadExtraLiterals, scanText } from "./public-guard";

// Fixtures are assembled at runtime so this file never trips the guard it tests.
const dot = (...parts: Array<string | number>) => parts.join(".");
const rules = (text: string, path = "docs/x.md", extras: string[] = []) =>
  scanText(path, text, extras).map((f) => f.rule);

describe("ipv4", () => {
  it("rejects private and public addresses", () => {
    expect(rules(`host ${dot(10, 0, 0, 5)}`)).toEqual(["ipv4"]);
    expect(rules(`host ${dot(192, 168, 1, 20)}`)).toEqual(["ipv4"]);
    expect(rules(`host ${dot(172, 16, 0, 1)}`)).toEqual(["ipv4"]);
    expect(rules(`host ${dot(8, 8, 8, 8)}:53`)).toEqual(["ipv4"]);
  });

  it("allows loopback and documentation ranges", () => {
    for (const ip of [
      dot(127, 0, 0, 1),
      dot(0, 0, 0, 0),
      dot(192, 0, 2, 7),
      dot(198, 51, 100, 9),
      dot(203, 0, 113, 200),
    ]) {
      expect(rules(`http://${ip}:7730`)).toEqual([]);
    }
  });

  it("ignores version-like and out-of-range strings", () => {
    expect(rules(`"zod": "^${dot(1, 2, 3)}"`)).toEqual([]);
    expect(rules(`v${dot(1, 2, 3, 4)}`)).toEqual([]);
    expect(rules(`zod@${dot(1, 2, 3, 4)}`)).toEqual([]);
    expect(rules(`>=${dot(1, 2, 3, 4)}`)).toEqual([]);
    expect(rules(`${dot(999, 1, 1, 1)}`)).toEqual([]);
    expect(rules(`${dot(10, 0, 0, 5, 7)}`)).toEqual([]);
    expect(rules(dot(2026, 10, 27, 1))).toEqual([]);
    expect(rules(`on ${dot(10, 0, 0, 5)}.`)).toEqual(["ipv4"]);
  });

  it("reports line numbers and truncates the value", () => {
    const [f] = scanText("a.md", `ok\nip ${dot(10, 1, 2, 3)}`);
    expect(f).toEqual({ path: "a.md", line: 2, rule: "ipv4", match: "10.1…" });
  });
});

describe("hostnames", () => {
  it("rejects tailnet hostnames", () => {
    expect(rules(`ssh box.${["tail1234", "ts", "net"].join(".")}`)).toEqual(["tailnet-host"]);
  });

  it("rejects mini./homelab./vps. hostnames on a real domain", () => {
    for (const label of ["mini", "homelab", "vps"]) {
      expect(rules(`https://iris.${label}.${["acme", "com"].join(".")}/x`)).toEqual(["infra-host"]);
    }
    expect(rules(`${["mini", "acme", "dev"].join(".")}`)).toEqual(["infra-host"]);
  });

  it("allows placeholders, example domains, localhost, .test and file names", () => {
    expect(rules("https://iris.mini.<domain>/x")).toEqual([]);
    expect(rules("iris.mini.example.com")).toEqual([]);
    expect(rules("vps.example.org")).toEqual([]);
    expect(rules("mini.localhost")).toEqual([]);
    expect(rules("iris.test and a.mini.test")).toEqual([]);
    expect(rules(".env.mini.otel.tpl and .env.mini.tpl")).toEqual([]);
    expect(rules("history-mini.agg.json")).toEqual([]);
    expect(rules("the mini. Next sentence")).toEqual([]);
  });
});

describe("extra literals", () => {
  it("rejects configured literals case-insensitively", () => {
    expect(rules("see Corp-Internal.example here", "a.md", ["corp-internal.example"])).toEqual([
      "extra-literal",
    ]);
  });

  it("loads from env and file, skipping comments and blanks", () => {
    const file = `${import.meta.dir}/__missing-guard-extra.txt`;
    expect(loadExtraLiterals({ IRIS_GUARD_EXTRA: " a.example , b.example,," }, file)).toEqual([
      "a.example",
      "b.example",
    ]);
    expect(loadExtraLiterals({}, file)).toEqual([]);
  });
});

describe("token shapes", () => {
  const cases: Array<[string, string, string]> = [
    ["github ghp", "token:github", `ghp${"_"}${"a1".repeat(18)}`],
    ["github gho", "token:github", `gho${"_"}${"b2".repeat(18)}`],
    ["github pat", "token:github", `github${"_"}pat${"_"}${"C3".repeat(15)}`],
    ["sk", "token:sk", `sk${"-"}${"proj1".repeat(6)}`],
    ["slack bot", "token:slack", `xoxb${"-"}1234567890-abcdefghij`],
    ["slack user", "token:slack", `xoxp${"-"}1234567890-abcdefghij`],
    ["aws", "token:aws", `AKIA${"ABCDEFGH12345678"}`],
    ["pem", "token:pem", `-----BEGIN ${"RSA "}PRIVATE KEY-----`],
    ["pem plain", "token:pem", `-----BEGIN ${""}PRIVATE KEY-----`],
    ["jwt", "token:jwt", `eyJ${"hbGciOiJIUzI1"}.${"eyJzdWIiOiIxMjM0"}.${"sig_value-9"}`],
    ["assigned", "token:assigned-secret", `API_KEY=${"a1b2c3d4".repeat(6)}`],
    ["assigned quoted", "token:assigned-secret", `"clientSecret": "${"Zx9/".repeat(12)}"`],
  ];

  for (const [name, rule, value] of cases) {
    it(`rejects ${name}`, () => {
      expect(rules(`x ${value} y`)).toContain(rule);
    });
  }

  it("never echoes a token in full", () => {
    const [f] = scanText("a.md", `ghp${"_"}${"a1".repeat(18)}`);
    expect(f?.match).toBe("ghp_…");
  });

  it("allows op:// refs, short values, plain words and long paths", () => {
    expect(rules("API_KEY=op://mini/iris/apple-api-key-with-a-very-long-field-name-9")).toEqual([]);
    expect(rules("HERMES_TOKEN=short")).toEqual([]);
    expect(rules(`SECRET_FILE=/Users/someone/${"very-long-dir-name/".repeat(4)}key`)).toEqual([]);
    expect(rules(`API_KEY=${"abcdefgh".repeat(6)}`)).toEqual([]);
    expect(rules("the sk- prefix and task-runner-with-a-long-name-123456789")).toEqual([]);
  });

  it("exempts the lockfile from token shapes but not from other rules", () => {
    const hash = `API_KEY=${"a1b2c3d4".repeat(6)}`;
    expect(rules(hash, "server/bun.lock")).toEqual([]);
    expect(rules(`${hash} ${dot(10, 0, 0, 5)}`, "server/bun.lock")).toEqual(["ipv4"]);
  });

  it("does not exempt docs/research", () => {
    expect(rules(`host ${dot(10, 0, 0, 5)}`, "docs/research/note.md")).toEqual(["ipv4"]);
  });
});
