#!/usr/bin/env bun
/**
 * TestFlight crash intake: lists the new `betaFeedbackCrashSubmissions` of `com.jkrumm.iris` from the App Store
 * Connect API, reads each crash log, and files one factory Issue per crash signature through `rd issue iris`.
 * Run hourly by `launchd/com.jkrumm.iris-testflight-crashes.plist.template` through `jobrun`.
 *
 *   bun scripts/testflight-crashes.ts [--dry-run] [--baseline] [--state <file>] [--artifacts <dir>]
 *
 *   --dry-run    read and print what would be filed; file nothing, write nothing (not even the logs)
 *   --baseline   mark every report that exists now as seen without filing (first install, already-fixed crashes)
 *
 * The Team key comes from `op://mini/apple-developer/asc-*` through `secrets-run` (never `op`, never argv);
 * the JWT lives in memory. Seen reports are remembered in `--state` (default `~/.iris/testflight-crashes-seen.json`).
 * The `--key testflight-crash-<oldest submission id of the group>` of each Issue makes a lost state file harmless:
 * the same group is filed again as the same Issue. Raw logs go to the gitignored `.artifacts/testflight-crashes/`
 * (0600); the tester's email and device facts never leave the API response.
 * The signature -> key map in the same file makes a later report of an already filed crash (same exception, top frame and build) reuse the Issue.
 * Exit codes: 0 ok, 1 an API, state or filing failure (a failed group stays unseen and is retried next hour), 2 usage.
 */
import { createPrivateKey, sign } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const BUNDLE_ID = "com.jkrumm.iris";
const ASC_BASE_URL = "https://api.appstoreconnect.apple.com";
const SECRET_ITEM = "op://mini/apple-developer";
const PAGE_LIMIT = 100;
const MAX_PAGES = 10;
const MAX_FRAMES = 12;
const MAX_COMMENT_CHARS = 600;
const REQUEST_TIMEOUT_MS = 30_000;
const JWT_TTL_SECONDS = 600;

const repoRoot = resolve(import.meta.dir, "..");
const out = (text: string) => process.stdout.write(`${text}\n`);
const err = (text: string) => process.stderr.write(`${text}\n`);

export interface Submission {
  id: string;
  createdDate: string;
  comment: string;
  osVersion: string;
}

export interface CrashApi {
  /** Every crash submission of the app, newest first. */
  listSubmissions(): Promise<Submission[]>;
  /** The symbolicated log text; "" when the submission has no log. */
  crashLog(id: string): Promise<string>;
}

export interface ParsedLog {
  exceptionType: string;
  build: string;
  /** Frames of the crashed thread that belong to the app, top first (`symbol (file:line)`, offsets dropped). */
  irisFrames: string[];
  /** The first app frame with a real symbol; "" when none resolved (`<deduplicated_symbol>` only, or no log). */
  topSymbol: string;
}

export interface Report extends ParsedLog {
  id: string;
  date: string;
  comment: string;
  osVersion: string;
  logText: string;
}

export interface IssueRequest {
  title: string;
  key: string;
  facts: Record<string, unknown>;
}

export interface Deps {
  api: CrashApi;
  /** Files one Issue; rejects when `rd` refuses. A repeated `key` is the factory's no-op. */
  fileIssue(request: IssueRequest): Promise<void>;
  stateFile: string;
  artifactsDir: string;
}

export interface Options {
  dryRun: boolean;
  baseline: boolean;
}

export interface Outcome {
  filed: number;
  seenBefore: number;
  failed: number;
}

/** One frame line: `7   Iris   \t0x0000000104261df4 DecisionsModel.answer(askID:text:) + 904 (DecisionsModel.swift:98)`. */
const FRAME =
  /^\d+\s+(\S+)\s+0x[0-9a-f]+\s+(.*?)(?:\s+\+\s+\d+)?(?:\s+\(([^()]*(?:\([^()]*\)[^()]*)*)\))?$/i;

export function parseCrashLog(logText: string): ParsedLog {
  const lines = logText.split("\n");
  const exceptionType = /^Exception Type:\s+(.+)$/m.exec(logText)?.[1]?.trim() ?? "unknown";
  const build = /^Version:\s+(.+)$/m.exec(logText)?.[1]?.trim() ?? "unknown";
  const start = lines.findIndex((line) => /^Thread \d+ Crashed:/.test(line));
  const frames: { symbol: string; location: string }[] = [];
  if (start >= 0) {
    for (const line of lines.slice(start + 1)) {
      if (line.trim() === "") break;
      const match = FRAME.exec(line.trim());
      const image = match?.[1];
      const symbol = match?.[2]?.trim();
      if (!image || !symbol || !image.startsWith("Iris")) continue;
      const location = match[3] ?? "";
      frames.push({ symbol, location: location === ":-1" || location === "" ? "" : location });
    }
  }
  const irisFrames = frames
    .slice(0, MAX_FRAMES)
    .map((f) => (f.location ? `${f.symbol} (${f.location})` : f.symbol));
  const top = frames.find((f) => !f.symbol.startsWith("<deduplicated_symbol>"));
  return { exceptionType, build, irisFrames, topSymbol: top?.symbol ?? "" };
}

/** One crash = same exception type, top app symbol and build. A report without a resolved symbol stands alone. */
export function signatureOf(report: Report): string {
  return report.topSymbol
    ? `${report.exceptionType}|${report.topSymbol}|${report.build}`
    : `alone|${report.id}`;
}

/** Groups the new reports by signature. */
export function groupReports(reports: Report[]): Report[][] {
  const groups = new Map<string, Report[]>();
  for (const report of reports) {
    const signature = signatureOf(report);
    groups.set(signature, [...(groups.get(signature) ?? []), report]);
  }
  return [...groups.values()];
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max)}…`;
}

export function buildIssue(group: Report[], logPaths: Map<string, string>): IssueRequest {
  const sorted = [...group].sort((a, b) => a.date.localeCompare(b.date));
  const oldest = sorted[0];
  if (!oldest) throw new Error("empty group");
  const where = oldest.topSymbol || "an unsymbolicated frame";
  const title = `fix(app): TestFlight crash in ${truncate(where, 80)} (${oldest.exceptionType})`;
  return {
    title,
    key: `testflight-crash-${oldest.id}`,
    facts: {
      source: "testflight-crash-intake",
      what: `${sorted.length} TestFlight crash report(s) of ${BUNDLE_ID} with one signature (${oldest.exceptionType}, top app frame ${where}). Find the cause in the app source, fix it, add a test that covers it. A crash fixed in a build newer than the reported one is a drop.`,
      reports: sorted.map((r) => ({
        id: r.id,
        date: r.date,
        build: r.build,
        osVersion: r.osVersion,
        ownerComment: truncate(r.comment, MAX_COMMENT_CHARS),
        exceptionType: r.exceptionType,
        irisFrames: r.irisFrames,
        logFile: logPaths.get(r.id) ?? null,
      })),
    },
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// App Store Connect client

export interface AscCredentials {
  keyId: string;
  issuerId: string;
  /** The .p8 key, PEM (normalised by `normalizePem`). */
  keyPem: string;
}

const base64url = (data: Buffer | string) => Buffer.from(data).toString("base64url");

export function createJwt(credentials: AscCredentials, nowSeconds: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: credentials.keyId, typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({
      iss: credentials.issuerId,
      iat: nowSeconds,
      exp: nowSeconds + JWT_TTL_SECONDS,
      aud: "appstoreconnect-v1",
    }),
  );
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {
    key: createPrivateKey(credentials.keyPem),
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${claims}.${base64url(signature)}`;
}

type Json = Record<string, unknown>;

function asRecord(value: unknown): Json {
  return typeof value === "object" && value !== null ? (value as Json) : {};
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export function createAscApi(
  credentials: AscCredentials,
  baseUrl: string = ASC_BASE_URL,
): CrashApi {
  const token = createJwt(credentials, Math.floor(Date.now() / 1000));

  async function get(path: string, allowMissing = false): Promise<Json | null> {
    const url = path.startsWith("http") ? path : `${baseUrl}${path}`;
    const response = await fetch(url, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (allowMissing && response.status === 404) return null;
    if (!response.ok)
      throw new Error(`App Store Connect answered ${response.status} for ${new URL(url).pathname}`);
    return asRecord(await response.json());
  }

  async function appId(): Promise<string> {
    const body = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
    const first = asRecord(Array.isArray(body?.["data"]) ? body["data"][0] : undefined);
    const id = asString(first["id"]);
    if (!id) throw new Error(`App Store Connect has no app ${BUNDLE_ID}`);
    return id;
  }

  return {
    async listSubmissions() {
      const id = await appId();
      const submissions: Submission[] = [];
      let next: string | null =
        `/v1/apps/${id}/betaFeedbackCrashSubmissions?limit=${PAGE_LIMIT}&sort=-createdDate`;
      for (let page = 0; next && page < MAX_PAGES; page++) {
        const body: Json | null = await get(next);
        for (const item of Array.isArray(body?.["data"]) ? body["data"] : []) {
          const row = asRecord(item);
          const attributes = asRecord(row["attributes"]);
          const submissionId = asString(row["id"]);
          if (!submissionId) continue;
          submissions.push({
            id: submissionId,
            createdDate: asString(attributes["createdDate"]),
            comment: asString(attributes["comment"]),
            osVersion: asString(attributes["osVersion"]),
          });
        }
        next = asString(asRecord(body?.["links"])["next"]) || null;
      }
      return submissions;
    },
    async crashLog(id) {
      const body = await get(
        `/v1/betaFeedbackCrashSubmissions/${encodeURIComponent(id)}/crashLog`,
        true,
      );
      return asString(asRecord(asRecord(body?.["data"])["attributes"])["logText"]);
    },
  };
}

async function secret(field: string): Promise<string> {
  const proc = Bun.spawn(["secrets-run", "read", `${SECRET_ITEM}/${field}`], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [text, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (code !== 0)
    throw new Error(`secrets-run read ${SECRET_ITEM}/${field} failed (make secrets-seed)`);
  return text.trim();
}

async function loadCredentials(): Promise<AscCredentials> {
  const [keyId, issuerId, keyP8] = await Promise.all([
    secret("asc-key-id"),
    secret("asc-issuer-id"),
    secret("asc-key-p8"),
  ]);
  return { keyId, issuerId, keyPem: normalizePem(keyP8) };
}

/**
 * The key as node:crypto needs it: 1Password turns the newlines of a concealed field into spaces and an env file holds a
 * literal `\n`; this rebuilds one PEM block with 64-character body lines (same rule as `pem_normalize` in
 * `scripts/apple-signing-key.sh` and `normalizePem` in `server/src/notify/select.ts`: keep the three in step; the server module is not imported because it pulls the whole notifier graph). Anything that is not one PEM block is returned as given.
 */
export function normalizePem(value: string): string {
  const flat = value.replaceAll("\\n", " ").replace(/\s+/g, " ").trim();
  const match = /^-----BEGIN ([A-Z0-9 ]+)----- (.*) -----END \1-----$/.exec(flat);
  if (!match) return value;
  const body = (match[2] ?? "").replaceAll(" ", "");
  const lines = body.match(/.{1,64}/g) ?? [];
  return [`-----BEGIN ${match[1]}-----`, ...lines, `-----END ${match[1]}-----`, ""].join("\n");
}

// ---------------------------------------------------------------------------------------------------------------------
// State and filing

interface State {
  /** Submission ids already handled (filed or baselined). */
  seen: Set<string>;
  /** Issue key per signature: a later report of the same crash reuses it, so the factory files nothing new. */
  keys: Record<string, string>;
}

async function loadState(stateFile: string): Promise<State> {
  if (!existsSync(stateFile)) return { seen: new Set(), keys: {} };
  const parsed = asRecord(JSON.parse(readFileSync(stateFile, "utf8")));
  const seen = parsed["seen"];
  const keys = asRecord(parsed["keys"]);
  return {
    seen: new Set(
      Array.isArray(seen) ? seen.filter((id): id is string => typeof id === "string") : [],
    ),
    keys: Object.fromEntries(
      Object.entries(keys).filter(
        (entry): entry is [string, string] => typeof entry[1] === "string",
      ),
    ),
  };
}

async function saveState(stateFile: string, state: State): Promise<void> {
  await mkdir(dirname(stateFile), { recursive: true });
  const tmp = `${stateFile}.tmp`;
  const body = JSON.stringify({ seen: [...state.seen].sort(), keys: state.keys }, null, 2);
  await writeFile(tmp, `${body}\n`, { mode: 0o600 });
  await rename(tmp, stateFile);
}

export async function rdFileIssue(request: IssueRequest): Promise<void> {
  const proc = Bun.spawn(
    ["rd", "issue", "iris", request.title, "--facts", "-", "--key", request.key],
    {
      stdin: new Blob([JSON.stringify(request.facts)]),
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0)
    throw new Error(`rd issue exited ${code}: ${truncate((stderr || stdout).trim(), 300)}`);
  out(`  filed ${request.key}: ${stdout.trim().split("\n")[0] ?? ""}`);
}

async function writeLogs(group: Report[], artifactsDir: string): Promise<Map<string, string>> {
  const paths = new Map<string, string>();
  await mkdir(artifactsDir, { recursive: true });
  for (const report of group) {
    if (!report.logText) continue;
    const path = join(artifactsDir, `${report.id}.crash`);
    await writeFile(path, report.logText, { mode: 0o600 });
    await chmod(path, 0o600);
    paths.set(report.id, path);
  }
  return paths;
}

export async function run(deps: Deps, options: Options): Promise<Outcome> {
  const submissions = await deps.api.listSubmissions();
  const state = await loadState(deps.stateFile);
  const fresh = submissions
    .filter((s) => !state.seen.has(s.id))
    .sort((a, b) => a.createdDate.localeCompare(b.createdDate));
  const outcome: Outcome = { filed: 0, seenBefore: submissions.length - fresh.length, failed: 0 };

  if (options.baseline) {
    if (!options.dryRun) {
      for (const s of fresh) state.seen.add(s.id);
      await saveState(deps.stateFile, state);
    }
    out(
      `  baseline: ${fresh.length} report(s) marked seen${options.dryRun ? " (dry run: nothing written)" : ""}`,
    );
    return outcome;
  }

  // Every log is read before anything is filed: an API failure here files nothing.
  const reports: Report[] = [];
  for (const s of fresh) {
    const logText = await deps.api.crashLog(s.id);
    reports.push({
      id: s.id,
      date: s.createdDate,
      comment: s.comment,
      osVersion: s.osVersion,
      logText,
      ...parseCrashLog(logText),
    });
  }

  for (const group of groupReports(reports)) {
    const signature = signatureOf(group[0] as Report);
    const paths = options.dryRun
      ? new Map<string, string>()
      : await writeLogs(group, deps.artifactsDir).catch((error: unknown) => {
          err(
            `  could not write the crash logs: ${error instanceof Error ? error.message : String(error)}`,
          );
          return new Map<string, string>();
        });
    const issue = buildIssue(group, paths);
    // The same crash seen again (same signature and build) reuses its Issue's key: the factory answers with the stored Issue.
    const earlierKey = state.keys[signature];
    if (earlierKey) issue.key = earlierKey;
    if (options.dryRun) {
      out(`  would file ${issue.key}: ${issue.title} (${group.length} report(s))`);
      for (const report of group) {
        out(
          `    ${report.id} ${report.date} build ${report.build}: ${report.irisFrames.slice(0, 3).join(" <- ") || "no app frames"}`,
        );
      }
      continue;
    }
    try {
      await deps.fileIssue(issue);
      for (const report of group) state.seen.add(report.id);
      if (!signature.startsWith("alone|")) state.keys[signature] = issue.key;
      await saveState(deps.stateFile, state);
      outcome.filed += 1;
    } catch (error) {
      outcome.failed += 1;
      err(
        `  could not file ${issue.key}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  out(
    `  testflight crashes: ${reports.length} new report(s), ${outcome.filed} Issue(s) filed, ${outcome.seenBefore} seen before`,
  );
  return outcome;
}

async function main(): Promise<number> {
  let values: { "dry-run"?: boolean; baseline?: boolean; state?: string; artifacts?: string };
  try {
    ({ values } = parseArgs({
      args: Bun.argv.slice(2),
      options: {
        "dry-run": { type: "boolean" },
        baseline: { type: "boolean" },
        state: { type: "string" },
        artifacts: { type: "string" },
      },
      strict: true,
    }));
  } catch (error) {
    err(
      `${error instanceof Error ? error.message : String(error)}\nusage: bun scripts/testflight-crashes.ts [--dry-run] [--baseline] [--state <file>] [--artifacts <dir>]`,
    );
    return 2;
  }
  try {
    const baseUrl = process.env["ASC_BASE_URL"] ?? ASC_BASE_URL;
    const deps: Deps = {
      api: createAscApi(await loadCredentials(), baseUrl),
      fileIssue: rdFileIssue,
      stateFile: values.state ?? join(homedir(), ".iris", "testflight-crashes-seen.json"),
      artifactsDir: values.artifacts ?? join(repoRoot, ".artifacts", "testflight-crashes"),
    };
    const outcome = await run(deps, {
      dryRun: values["dry-run"] === true,
      baseline: values.baseline === true,
    });
    return outcome.failed > 0 ? 1 : 0;
  } catch (error) {
    err(`  testflight-crashes failed: ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

if (import.meta.main) process.exit(await main());
