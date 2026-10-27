import { afterEach, describe, expect, it } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  formatSummary,
  listSegments,
  parseCliArgs,
  sendMemo,
  splitAudio,
  UsageError,
  type MemoWire,
  type Options,
} from "./send-memo";

const hasFfmpeg = Boolean(Bun.which("ffmpeg"));
const TOKEN = "test-token";
const cleanup: string[] = [];

afterEach(async () => {
  await Promise.all(cleanup.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir() {
  const dir = await mkdtemp(join(tmpdir(), "send-memo-test-"));
  cleanup.push(dir);
  return dir;
}

async function makeTone(seconds: number) {
  const file = join(await tempDir(), "tone.wav");
  const proc = Bun.spawn(
    [
      "ffmpeg",
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      `sine=frequency=440:duration=${seconds}`,
      file,
    ],
    { stderr: "pipe" },
  );
  expect(await proc.exited).toBe(0);
  return file;
}

describe("parseCliArgs", () => {
  it("applies defaults and reads the token from the env", () => {
    expect(parseCliArgs(["a.m4a"], { IRIS_TOKEN: "t" })).toEqual({
      file: "a.m4a",
      url: "http://127.0.0.1:7730",
      token: "t",
      mode: "auto",
      waitSeconds: 300,
    });
  });

  it("prefers flags over env and trims the trailing slash", () => {
    const options = parseCliArgs(
      [
        "a.m4a",
        "--url",
        "https://iris.example.com/",
        "--token",
        "flag",
        "--mode",
        "tab",
        "--wait=12",
      ],
      { IRIS_TOKEN: "env", IRIS_URL: "http://other" },
    );
    expect(options).toMatchObject({
      url: "https://iris.example.com",
      token: "flag",
      mode: "tab",
      waitSeconds: 12,
    });
  });

  it("takes --text instead of a file, and not both", () => {
    expect(parseCliArgs(["--text", "kauf Milch", "--mode", "hermes"], { IRIS_TOKEN: "t" })).toEqual(
      {
        text: "kauf Milch",
        url: "http://127.0.0.1:7730",
        token: "t",
        mode: "hermes",
        waitSeconds: 300,
      },
    );
    expect(() => parseCliArgs(["a.m4a", "--text", "x"], { IRIS_TOKEN: "t" })).toThrow(UsageError);
    expect(() => parseCliArgs(["--text", "  "], { IRIS_TOKEN: "t" })).toThrow(UsageError);
  });

  it("rejects bad usage", () => {
    expect(() => parseCliArgs(["a.m4a"], {})).toThrow(UsageError);
    expect(() => parseCliArgs([], { IRIS_TOKEN: "t" })).toThrow(UsageError);
    expect(() => parseCliArgs(["a", "b"], { IRIS_TOKEN: "t" })).toThrow(UsageError);
    expect(() => parseCliArgs(["a", "--mode", "nope"], { IRIS_TOKEN: "t" })).toThrow(UsageError);
    expect(() => parseCliArgs(["a", "--wait", "0"], { IRIS_TOKEN: "t" })).toThrow(UsageError);
    expect(() => parseCliArgs(["a", "--bogus"], { IRIS_TOKEN: "t" })).toThrow(UsageError);
  });
});

describe("listSegments", () => {
  it("sorts numerically and ignores other files", async () => {
    const dir = await tempDir();
    for (const name of ["seg00010.m4a", "seg00002.m4a", "seg00001.m4a", "notes.txt"]) {
      await writeFile(join(dir, name), "x");
    }
    const names = (await listSegments(dir)).map((path) => path.split("/").pop());
    expect(names).toEqual(["seg00001.m4a", "seg00002.m4a", "seg00010.m4a"]);
  });
});

describe("formatSummary", () => {
  const memo: MemoWire = {
    id: "0190aaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    state: "notified",
    failedStep: null,
    error: null,
    audioSeconds: 24.5,
    transcript: "x".repeat(300),
    replyText: "hello\nworld",
    summary: { headline: "Head", detail: "Detail" },
    steps: [
      {
        step: "transcribe",
        status: "done",
        startedAt: "2026-01-01T00:00:00.000Z",
        finishedAt: "2026-01-01T00:00:01.500Z",
        error: null,
        costUsd: 0.001,
      },
      {
        step: "summarize",
        status: "done",
        startedAt: "2026-01-01T00:00:02.000Z",
        finishedAt: "2026-01-01T00:00:03.000Z",
        error: null,
        costUsd: 0.0005,
      },
      {
        step: "notify",
        status: "done",
        startedAt: null,
        finishedAt: null,
        error: null,
        costUsd: null,
      },
    ],
  };

  it("prints ids, clipped text, timings and summed cost", () => {
    const text = formatSummary(memo);
    expect(text).toContain("trace       0190aaaabbbb4ccc8dddeeeeeeeeeeee");
    expect(text).toContain(`transcript  ${"x".repeat(200)}...`);
    expect(text).toContain("reply       hello world");
    expect(text).toContain("transcribe:done 1.5s  summarize:done 1.0s  notify:done");
    expect(text).toContain("costUsd     $0.0015");
  });

  it("shows the failed step and tolerates missing fields", () => {
    const text = formatSummary({ id: "a-b", state: "failed", failedStep: "act", error: "boom" });
    expect(text).toContain("failed      act: boom");
    expect(text).toContain("costUsd     -");
  });
});

describe.skipIf(!hasFfmpeg)("splitAudio", () => {
  it("splits 25 s of tone into three playable m4a segments", async () => {
    const file = await makeTone(25);
    const dir = await tempDir();
    const segments = await splitAudio({ file, dir });
    expect(segments).toHaveLength(3);
    for (const segment of segments) {
      const bytes = await Bun.file(segment).bytes();
      // ISO base media files carry the `ftyp` box at offset 4.
      expect(new TextDecoder().decode(bytes.slice(4, 8))).toBe("ftyp");
    }
  });
});

interface FakeOptions {
  finalState: string;
  /** Segment 1 answers 500 on its first PUT. */
  flakyFirstPut?: boolean;
  /** Segment 1 answers 200 on its first PUT but is not stored. */
  dropFirstPut?: boolean;
}

const json = (body: unknown, status = 200) => Response.json(body, { status });

/** In-process stand-in for the /v1 memo routes. */
function startFake(fake: FakeOptions) {
  const segments = new Map<number, number>();
  const log: string[] = [];
  let created: { id: string; mode: string; text?: string } | null = null;
  let completeCount = 0;
  let polls = 0;
  let puts1 = 0;

  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const route = `${request.method} ${url.pathname.replace(/[0-9a-f-]{36}/, ":id")}`;
      log.push(route);
      if (request.headers.get("authorization") !== `Bearer ${TOKEN}`) {
        return json({ error: "unauthorized", message: "no" }, 401);
      }
      if (route === "POST /v1/memos") {
        created = (await request.json()) as { id: string; mode: string };
        return json({ ...created, state: "receiving" }, 201);
      }
      if (route === "POST /v1/memos/text") {
        created = (await request.json()) as { id: string; mode: string; text: string };
        return json({ ...created, state: "transcribed" }, 202);
      }
      const put = /^PUT \/v1\/memos\/:id\/segments\/(\d+)$/.exec(route);
      if (put) {
        const n = Number(put[1]);
        if (request.headers.get("content-type") !== "audio/mp4")
          return json({ error: "bad_request", message: "type" }, 400);
        const bytes = await request.arrayBuffer();
        if (n === 1) {
          puts1 += 1;
          if (fake.flakyFirstPut && puts1 === 1)
            return json({ error: "boom", message: "flaky" }, 500);
          if (fake.dropFirstPut && puts1 === 1) return json(null);
        }
        segments.set(n, bytes.byteLength);
        return json(null);
      }
      if (route === "POST /v1/memos/:id/complete") {
        completeCount += 1;
        const { segmentCount } = (await request.json()) as { segmentCount: number };
        const missing = Array.from({ length: segmentCount }, (_, i) => i).filter(
          (i) => !segments.has(i),
        );
        if (missing.length > 0)
          return json({ error: "missing_segments", message: "missing", missing }, 422);
        return json({ state: "received", segmentCount }, 202);
      }
      if (route === "GET /v1/memos/:id/result") {
        polls += 1;
        return json({ state: fake.finalState }, polls < 2 ? 202 : 200);
      }
      if (route === "GET /v1/memos/:id") {
        return json({
          id: created?.id,
          state: fake.finalState,
          failedStep: fake.finalState === "failed" ? "transcribe" : null,
          error: fake.finalState === "failed" ? "gateway down" : null,
          audioSeconds: 24.5,
          transcript: "hello iris",
          replyText: "hi",
          summary: { headline: "Greeting", detail: "Said hello" },
          steps: [
            {
              step: "transcribe",
              status: "done",
              startedAt: "2026-01-01T00:00:00.000Z",
              finishedAt: "2026-01-01T00:00:02.000Z",
              error: null,
              costUsd: 0.002,
            },
          ],
        });
      }
      return json({ error: "not_found", message: route }, 404);
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    log,
    segments,
    created: () => created,
    completeCount: () => completeCount,
    stop: () => server.stop(true),
  };
}

async function run(fake: FakeOptions, overrides: Partial<Options> = {}) {
  const server = startFake(fake);
  try {
    const options: Options = {
      file: await makeTone(25),
      url: server.url,
      token: TOKEN,
      mode: "hermes",
      waitSeconds: 30,
      ...overrides,
    };
    const code = await sendMemo(options);
    return { code, server };
  } finally {
    server.stop();
  }
}

describe("sendMemo --text against a fake server", () => {
  it("posts the text to /memos/text, uploads nothing, and exits 0 on notified", async () => {
    const server = startFake({ finalState: "notified" });
    try {
      const code = await sendMemo({
        text: "kauf Milch",
        url: server.url,
        token: TOKEN,
        mode: "hermes",
        waitSeconds: 30,
      });
      expect(code).toBe(0);
      expect(server.created()).toMatchObject({ mode: "hermes", text: "kauf Milch" });
      expect(server.log.filter((r) => r.startsWith("PUT") || r.endsWith("/complete"))).toEqual([]);
      expect(server.log).toContain("POST /v1/memos/text");
    } finally {
      server.stop();
    }
  });
});

describe.skipIf(!hasFfmpeg)("sendMemo against a fake server", () => {
  it("uploads all segments 0-based, completes and exits 0 on notified", async () => {
    const { code, server } = await run({ finalState: "notified" });
    expect(code).toBe(0);
    expect([...server.segments.keys()].toSorted()).toEqual([0, 1, 2]);
    expect(server.created()?.mode).toBe("hermes");
    expect(server.created()?.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(server.log.filter((r) => r === "GET /v1/memos/:id/result")).toHaveLength(2);
  });

  it("retries a 5xx segment upload once", async () => {
    const { code, server } = await run({ finalState: "notified", flakyFirstPut: true });
    expect(code).toBe(0);
    expect(server.segments.size).toBe(3);
  });

  it("re-uploads segments listed by a 422 and completes again", async () => {
    const { code, server } = await run({ finalState: "notified", dropFirstPut: true });
    expect(code).toBe(0);
    expect(server.completeCount()).toBe(2);
    expect(server.segments.size).toBe(3);
  });

  it("exits 1 on failed", async () => {
    expect((await run({ finalState: "failed" })).code).toBe(1);
  });

  it("exits 2 on needs_route", async () => {
    expect((await run({ finalState: "needs_route" })).code).toBe(2);
  });

  it("surfaces a rejected token as an error", async () => {
    const server = startFake({ finalState: "notified" });
    try {
      const options: Options = {
        file: await makeTone(5),
        url: server.url,
        token: "wrong",
        mode: "auto",
        waitSeconds: 5,
      };
      await expect(sendMemo(options)).rejects.toThrow("401");
    } finally {
      server.stop();
    }
  });
});
