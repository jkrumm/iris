#!/usr/bin/env bun
/**
 * Public-repo guard: rejects secrets and private infrastructure details in TRACKED files.
 *
 * Rules: private/public IPv4, tailnet hostnames, `mini.`/`homelab.`/`vps.` hostnames on a real
 * domain, token shapes (GitHub, `sk-`, Slack, AWS, PEM private keys, JWTs, long values assigned
 * to *KEY/TOKEN/SECRET* names), and extra literals.
 *
 * The real domain is NEVER written into this repo. Literals to forbid are read at runtime from
 * untracked sources: env `IRIS_GUARD_EXTRA` (comma list) and `~/.config/iris/guard-extra.txt`
 * (one per line, `#` comments). Seed it once per machine:
 *   mkdir -p ~/.config/iris && echo '<real-domain>' >> ~/.config/iris/guard-extra.txt
 * CI has no such file and relies on the generic hostname rule.
 *
 * Usage: `bun scripts/public-guard.ts` (all tracked files) | `--staged` (staged blobs, pre-commit).
 * Exit 1 lists `path:line: rule (first 4 chars…)`; matched values are never printed in full.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type Finding = { path: string; line: number; rule: string; match: string };

/** Lockfiles carry integrity hashes that look like secrets; they skip token-shape rules only. */
const TOKEN_EXEMPT_PATHS = new Set(["server/bun.lock"]);

const IPV4 = /(?<![\w.@^~<>])(?<!>=)(?<!<=)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?!\d|\.\d)/g;
const TAILNET_HOST = /(?<![\w-])(?:[a-z0-9-]+\.)+ts\.net(?![\w-])/gi;
const INFRA_HOST = /(?<![\w-])(?:mini|homelab|vps)(?:\.[a-z0-9-]+)+(?![\w-])/gi;
const SAFE_TLDS = new Set([
  "test",
  "localhost",
  "tpl",
  "template",
  "ts",
  "js",
  "json",
  "md",
  "sh",
  "yml",
  "yaml",
  "toml",
  "txt",
  "log",
  "err",
  "plist",
  "lock",
  "env",
]);
const SAFE_DOMAIN_LABELS = new Set(["example"]);

const TOKEN_RULES: Array<{ rule: string; pattern: RegExp }> = [
  {
    rule: "token:github",
    pattern: /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/g,
  },
  { rule: "token:sk", pattern: /\bsk-(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{20,}/g },
  { rule: "token:slack", pattern: /\bxox[bp]-[A-Za-z0-9-]{10,}/g },
  { rule: "token:aws", pattern: /\bAKIA[0-9A-Z]{16}\b/g },
  { rule: "token:pem", pattern: /-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----/g },
  { rule: "token:jwt", pattern: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/g },
  {
    rule: "token:assigned-secret",
    pattern:
      /[A-Za-z0-9_]*(?:KEY|TOKEN|SECRET)[A-Za-z0-9_]*["']?\s*[:=]\s*["']?(?=[A-Za-z0-9+/_=-]*\d)(?=[A-Za-z0-9+/_=-]*[A-Za-z])([A-Za-z0-9+/_=-]{40,})/gi,
  },
];

const ALLOWED_IP = [/^127\./, /^0\.0\.0\.0$/, /^192\.0\.2\./, /^198\.51\.100\./, /^203\.0\.113\./];

const redact = (value: string): string => `${value.slice(0, 4)}…`;

function isIpv4(octets: string[]): boolean {
  return octets.every((o) => Number(o) <= 255 && !(o.length > 1 && o.startsWith("0")));
}

function isForbiddenHost(host: string): boolean {
  const labels = host.toLowerCase().split(".");
  const tld = labels.at(-1) ?? "";
  if (labels.length < 3) return false;
  if (SAFE_TLDS.has(tld)) return false;
  return !labels.some((label) => SAFE_DOMAIN_LABELS.has(label));
}

export function scanText(path: string, text: string, extraLiterals: string[] = []): Finding[] {
  const findings: Finding[] = [];
  const tokenScan = !TOKEN_EXEMPT_PATHS.has(path);
  const extras = extraLiterals.map((l) => l.toLowerCase()).filter(Boolean);
  const add = (line: number, rule: string, match: string) =>
    findings.push({ path, line, rule, match: redact(match) });

  text.split("\n").forEach((raw, index) => {
    const line = index + 1;
    const content = raw.replace(/op:\/\/\S+/g, (m) => " ".repeat(m.length));
    const lower = content.toLowerCase();

    for (const m of content.matchAll(IPV4)) {
      const octets = m.slice(1, 5);
      if (!isIpv4(octets) || ALLOWED_IP.some((re) => re.test(octets.join(".")))) continue;
      add(line, "ipv4", m[0]);
    }
    for (const m of content.matchAll(TAILNET_HOST)) add(line, "tailnet-host", m[0]);
    for (const m of content.matchAll(INFRA_HOST)) {
      if (isForbiddenHost(m[0])) add(line, "infra-host", m[0]);
    }
    for (const literal of extras) {
      const at = lower.indexOf(literal);
      if (at !== -1) add(line, "extra-literal", content.slice(at, at + literal.length));
    }
    if (!tokenScan) return;
    for (const { rule, pattern } of TOKEN_RULES) {
      for (const m of content.matchAll(pattern)) add(line, rule, m[0]);
    }
  });
  return findings;
}

export function loadExtraLiterals(
  env: Record<string, string | undefined> = process.env,
  file = join(homedir(), ".config", "iris", "guard-extra.txt"),
): string[] {
  const fromEnv = (env["IRIS_GUARD_EXTRA"] ?? "").split(",");
  const fromFile = existsSync(file) ? readFileSync(file, "utf8").split("\n") : [];
  return [...fromEnv, ...fromFile]
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("#"));
}

function git(args: string[]): Buffer {
  const proc = Bun.spawnSync(["git", ...args], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${proc.stderr.toString()}`);
  return Buffer.from(proc.stdout);
}

const splitNul = (buf: Buffer): string[] => buf.toString("utf8").split("\0").filter(Boolean);
const isBinary = (buf: Buffer): boolean => buf.includes(0);

function collect(staged: boolean): Array<{ path: string; text: string }> {
  const paths = staged
    ? splitNul(git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"]))
    : splitNul(git(["ls-files", "-z"]));
  const files: Array<{ path: string; text: string }> = [];
  for (const path of paths) {
    const blob = staged ? git(["show", `:${path}`]) : readFileSync(path);
    if (isBinary(blob)) continue;
    files.push({ path, text: blob.toString("utf8") });
  }
  return files;
}

export function main(argv: string[]): number {
  const staged = argv.includes("--staged");
  const extras = loadExtraLiterals();
  const findings = collect(staged).flatMap(({ path, text }) => scanText(path, text, extras));
  if (findings.length === 0) return 0;
  for (const f of findings) process.stderr.write(`${f.path}:${f.line}: ${f.rule} (${f.match})\n`);
  process.stderr.write(`public-guard: ${findings.length} finding(s)\n`);
  return 1;
}

if (import.meta.main) {
  const root = git(["rev-parse", "--show-toplevel"]).toString().trim();
  process.chdir(root);
  process.exit(main(process.argv.slice(2)));
}
