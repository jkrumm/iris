import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createAscApi,
  createJwt,
  factoryIssueArgv,
  fileFactoryIssue,
  normalizePem,
  parseCrashLog,
  run,
  type AscCredentials,
  type Deps,
  type IssueRequest,
} from "./testflight-crashes";

const EMAIL = "tester@example.com";

function crashLog(params: { top: string; build?: string; exception?: string }): string {
  return [
    "Incident Identifier: 28FA605C-A374-421D-A9F9-1C564D2B9D56",
    `Version:             0.1.0 (${params.build ?? "702.498327"})`,
    `Exception Type:  ${params.exception ?? "EXC_CRASH (SIGABRT)"}`,
    "Triggered by Thread:  0",
    "",
    "Thread 0 Crashed:",
    "0   libsystem_kernel.dylib        \t0x0000000249ec31d0 __pthread_kill + 8 (:-1)",
    "1   libswiftCore.dylib            \t0x0000000197547074 swift_beginAccess + 572 (:-1)",
    `2   Iris                          \t0x0000000104261df4 ${params.top} + 12 (Model.swift:98)`,
    "3   Iris                          \t0x0000000104269b95 <deduplicated_symbol> + 1",
    "4   libswift_Concurrency.dylib    \t0x000000019896b385 completeTaskWithClosure(swift::AsyncContext*, swift::SwiftError*) + 1 (:-1)",
    "",
    "Thread 1:",
    "0   Iris                          \t0x0000000104261df4 NotCrashed.frame + 1 (Other.swift:1)",
    "",
  ].join("\n");
}

interface FakeReport {
  id: string;
  createdDate: string;
  comment: string;
  log: string | null;
}

const keyPair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const credentials: AscCredentials = {
  keyId: "KEY123",
  issuerId: "issuer-1",
  keyPem: keyPair.privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
};

let reports: FakeReport[] = [];
let failWith: number | null = null;
let authorized = true;
let server: ReturnType<typeof Bun.serve>;
let baseUrl = "";

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      const token = request.headers.get("authorization")?.replace("Bearer ", "") ?? "";
      const [header, claims, signature] = token.split(".");
      authorized =
        Boolean(header && claims && signature) &&
        verify(
          "sha256",
          Buffer.from(`${header}.${claims}`),
          { key: keyPair.publicKey, dsaEncoding: "ieee-p1363" },
          Buffer.from(signature ?? "", "base64url"),
        );
      if (!authorized) return new Response("{}", { status: 401 });
      if (failWith) return new Response("{}", { status: failWith });
      if (url.pathname === "/v1/apps") return Response.json({ data: [{ id: "app-1" }] });
      if (url.pathname === "/v1/apps/app-1/betaFeedbackCrashSubmissions") {
        return Response.json({
          data: [...reports]
            .sort((a, b) => b.createdDate.localeCompare(a.createdDate))
            .map((r) => ({
              id: r.id,
              attributes: {
                createdDate: r.createdDate,
                comment: r.comment,
                osVersion: "26.6.1",
                email: EMAIL,
              },
            })),
          links: {},
        });
      }
      const log = /^\/v1\/betaFeedbackCrashSubmissions\/([^/]+)\/crashLog$/.exec(url.pathname);
      const report = reports.find((r) => r.id === log?.[1]);
      if (!report?.log) return new Response("{}", { status: 404 });
      return Response.json({ data: { attributes: { logText: report.log } } });
    },
  });
  baseUrl = `http://127.0.0.1:${server.port}`;
});

afterAll(() => server.stop(true));

const cleanup: string[] = [];
afterEach(async () => {
  reports = [];
  failWith = null;
  await Promise.all(cleanup.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "tf-crashes-test-"));
  cleanup.push(dir);
  const filed: IssueRequest[] = [];
  let rdFails = false;
  const deps: Deps = {
    api: createAscApi(credentials, baseUrl),
    fileIssue: async (request) => {
      if (rdFails) throw new Error("factory refused");
      filed.push(request);
    },
    stateFile: join(dir, "state", "seen.json"),
    artifactsDir: join(dir, "artifacts"),
  };
  return { deps, filed, dir, failRd: () => (rdFails = true) };
}

const board = "DecisionsModel.board.getter";

describe("parseCrashLog", () => {
  it("reads build, exception, and the crashed thread's app frames only", () => {
    const parsed = parseCrashLog(crashLog({ top: board }));
    expect(parsed.build).toBe("0.1.0 (702.498327)");
    expect(parsed.exceptionType).toBe("EXC_CRASH (SIGABRT)");
    expect(parsed.irisFrames).toEqual([`${board} (Model.swift:98)`, "<deduplicated_symbol>"]);
    expect(parsed.topSymbol).toBe(board);
  });

  it("has no top symbol when only deduplicated frames resolve, and survives an empty log", () => {
    const log = crashLog({ top: "<deduplicated_symbol>" });
    expect(parseCrashLog(log).topSymbol).toBe("");
    expect(parseCrashLog("")).toMatchObject({
      irisFrames: [],
      topSymbol: "",
      exceptionType: "unknown",
    });
  });
});

describe("createJwt", () => {
  it("is an ES256 token for the App Store Connect audience", () => {
    const [h, c] = createJwt(credentials, 1000).split(".");
    expect(JSON.parse(Buffer.from(h ?? "", "base64url").toString())).toEqual({
      alg: "ES256",
      kid: "KEY123",
      typ: "JWT",
    });
    expect(JSON.parse(Buffer.from(c ?? "", "base64url").toString())).toMatchObject({
      iss: "issuer-1",
      aud: "appstoreconnect-v1",
      exp: 1600,
    });
  });
});

describe("run", () => {
  it("files one Issue for a new report, with facts and no tester data, and a rerun files none", async () => {
    reports = [
      {
        id: "A1",
        createdDate: "2026-11-06T16:00:00Z",
        comment: "crashed on answer",
        log: crashLog({ top: board }),
      },
    ];
    const { deps, filed } = await harness();
    const first = await run(deps, { dryRun: false, baseline: false });
    expect(first).toEqual({ filed: 1, seenBefore: 0, failed: 0 });
    expect(filed).toHaveLength(1);
    const issue = filed[0];
    expect(issue?.key).toBe("testflight-crash-A1");
    expect(issue?.title).toContain(board);
    expect(JSON.stringify(issue)).not.toContain(EMAIL);
    expect(JSON.stringify(issue?.facts)).toContain("crashed on answer");
    const logFile = join(deps.artifactsDir, "A1.crash");
    expect(readFileSync(logFile, "utf8")).toContain("Incident Identifier");
    expect(statSync(logFile).mode & 0o777).toBe(0o600);

    const second = await run(deps, { dryRun: false, baseline: false });
    expect(second).toEqual({ filed: 0, seenBefore: 1, failed: 0 });
    expect(filed).toHaveLength(1);
  });

  it("puts reports with the same top app frame on one Issue keyed by the oldest, and others on their own", async () => {
    reports = [
      {
        id: "NEW",
        createdDate: "2026-11-06T20:00:00Z",
        comment: "again",
        log: crashLog({ top: board }),
      },
      {
        id: "OLD",
        createdDate: "2026-11-06T16:00:00Z",
        comment: "first",
        log: crashLog({ top: board }),
      },
      {
        id: "OTHER",
        createdDate: "2026-11-06T18:00:00Z",
        comment: "",
        log: crashLog({ top: "PushAppDelegate.didReceive" }),
      },
    ];
    const { deps, filed } = await harness();
    await run(deps, { dryRun: false, baseline: false });
    expect(filed.map((f) => f.key).sort()).toEqual([
      "testflight-crash-OLD",
      "testflight-crash-OTHER",
    ]);
    const grouped = filed.find((f) => f.key === "testflight-crash-OLD");
    expect(grouped?.facts["reports"]).toHaveLength(2);
  });

  it("reuses the Issue key for a later report of the same crash and build, and files a new Issue for a new build", async () => {
    reports = [
      {
        id: "FIRST",
        createdDate: "2026-11-06T16:00:00Z",
        comment: "",
        log: crashLog({ top: board }),
      },
    ];
    const { deps, filed } = await harness();
    await run(deps, { dryRun: false, baseline: false });
    reports.push(
      {
        id: "AGAIN",
        createdDate: "2026-11-07T08:00:00Z",
        comment: "",
        log: crashLog({ top: board }),
      },
      {
        id: "NEWBUILD",
        createdDate: "2026-11-07T09:00:00Z",
        comment: "",
        log: crashLog({ top: board, build: "710.1" }),
      },
    );
    await run(deps, { dryRun: false, baseline: false });
    expect(filed.map((f) => f.key)).toEqual([
      "testflight-crash-FIRST",
      "testflight-crash-FIRST",
      "testflight-crash-NEWBUILD",
    ]);
  });

  it("files a report whose log is missing, on its own", async () => {
    reports = [{ id: "NOLOG", createdDate: "2026-11-06T16:00:00Z", comment: "no log", log: null }];
    const { deps, filed } = await harness();
    await run(deps, { dryRun: false, baseline: false });
    expect(filed.map((f) => f.key)).toEqual(["testflight-crash-NOLOG"]);
  });

  it("files nothing and throws when the API fails", async () => {
    reports = [
      { id: "A1", createdDate: "2026-11-06T16:00:00Z", comment: "", log: crashLog({ top: board }) },
    ];
    failWith = 500;
    const { deps, filed } = await harness();
    await expect(run(deps, { dryRun: false, baseline: false })).rejects.toThrow("500");
    expect(filed).toHaveLength(0);
    expect(existsSync(deps.stateFile)).toBe(false);
  });

  it("leaves a report unseen when filing fails, so the next run retries it", async () => {
    reports = [
      { id: "A1", createdDate: "2026-11-06T16:00:00Z", comment: "", log: crashLog({ top: board }) },
    ];
    const { deps, filed, failRd } = await harness();
    failRd();
    expect(await run(deps, { dryRun: false, baseline: false })).toMatchObject({
      filed: 0,
      failed: 1,
    });
    expect(existsSync(deps.stateFile)).toBe(false);
    expect(filed).toHaveLength(0);
  });

  it("dry run files and writes nothing; baseline marks seen without filing", async () => {
    reports = [
      { id: "A1", createdDate: "2026-11-06T16:00:00Z", comment: "", log: crashLog({ top: board }) },
    ];
    const { deps, filed } = await harness();
    await run(deps, { dryRun: true, baseline: false });
    expect(filed).toHaveLength(0);
    expect(existsSync(deps.stateFile)).toBe(false);
    expect(existsSync(deps.artifactsDir)).toBe(false);

    await run(deps, { dryRun: false, baseline: true });
    expect(filed).toHaveLength(0);
    expect(await run(deps, { dryRun: false, baseline: false })).toEqual({
      filed: 0,
      seenBefore: 1,
      failed: 0,
    });
  });
});

describe("filing through the factory CLI", () => {
  const request: IssueRequest = {
    title: "fix(app): TestFlight crash in it's.board (EXC_CRASH)",
    key: "testflight-crash-A1",
    facts: { why: "w", what: "x", change: "c", acceptance: "a" },
  };

  it("builds the owner-path argv with the key", () => {
    expect(factoryIssueArgv(request)).toEqual([
      "factory",
      "issue",
      "new",
      "--repo",
      "iris",
      "--title",
      request.title,
      "--facts",
      "-",
      "--key",
      "testflight-crash-A1",
      "--alone",
    ]);
  });

  /** A fake `factory` first on PATH records its argv (one per line) and stdin; exit code and message are set per test. */
  async function fakeFactory(exitCode: number) {
    const dir = await mkdtemp(join(tmpdir(), "tf-crashes-factory-"));
    cleanup.push(dir);
    const bin = join(dir, "factory");
    await writeFile(
      bin,
      `#!/bin/sh\nprintf '%s\\n' "$@" > "${dir}/argv"\ncat > "${dir}/stdin"\necho "issue_9 filed"\necho "boom" >&2\nexit ${exitCode}\n`,
    );
    await chmod(bin, 0o755);
    return dir;
  }

  it("spawns `factory` with that argv and the facts JSON on stdin", async () => {
    const dir = await fakeFactory(0);
    const path = process.env["PATH"];
    process.env["PATH"] = `${dir}:${path}`;
    try {
      await fileFactoryIssue(request);
    } finally {
      process.env["PATH"] = path;
    }
    expect(readFileSync(join(dir, "argv"), "utf8").trimEnd().split("\n")).toEqual(
      factoryIssueArgv(request).slice(1),
    );
    expect(JSON.parse(readFileSync(join(dir, "stdin"), "utf8"))).toEqual(request.facts);
  });

  it("throws with the CLI's message when factory exits non-zero", async () => {
    const dir = await fakeFactory(3);
    const path = process.env["PATH"];
    process.env["PATH"] = `${dir}:${path}`;
    try {
      await expect(fileFactoryIssue(request)).rejects.toThrow("factory issue new exited 3: boom");
    } finally {
      process.env["PATH"] = path;
    }
  });

  it("dry run prints the exact command and the facts", async () => {
    reports = [
      { id: "A1", createdDate: "2026-11-06T16:00:00Z", comment: "", log: crashLog({ top: board }) },
    ];
    const { deps } = await harness();
    const lines: string[] = [];
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string | Uint8Array) => {
      lines.push(String(chunk));
      return true;
    }) as typeof process.stdout.write;
    try {
      await run(deps, { dryRun: true, baseline: false });
    } finally {
      process.stdout.write = write;
    }
    const text = lines.join("");
    expect(text).toContain("command: factory issue new --repo iris --title '");
    expect(text).toContain("--facts - --key testflight-crash-A1 --alone");
    expect(text).toContain('facts (stdin): {"');
  });
});

describe("normalizePem", () => {
  it("rebuilds a key whose newlines became spaces or literal \\n, and leaves other values alone", () => {
    const pem = credentials.keyPem.trim();
    const flat = pem.replaceAll("\n", " ");
    const escaped = pem.replaceAll("\n", "\\n");
    expect(normalizePem(flat)).toBe(`${pem}\n`);
    expect(normalizePem(escaped)).toBe(`${pem}\n`);
    expect(normalizePem("not a key")).toBe("not a key");
  });
});
