import { link, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Clock } from "../ports/clock.js";
import { systemClock } from "../ports/clock.js";
import type { Delivery, Destination } from "../ports/destination.js";
import { log } from "../telemetry/log.js";
import { withSpan } from "../telemetry/otel.js";

const INBOX = "Inbox";
const TITLE_MAX = 60;
const SLUG_MAX = 50;
const FALLBACK_TITLE = "Voice memo";
const FALLBACK_SLUG = "memo";
const FRONTMATTER_READ_BYTES = 1024;

const DEFAULT_LOCK_DIR = join(homedir(), "Library", "Caches", "brain-sync.lock");
const DEFAULT_LOCK_ATTEMPTS = 5;
const DEFAULT_LOCK_BASE_DELAY_MS = 1_000;
const LOCK_MAX_DELAY_MS = 10_000;
const DEFAULT_PUSH_TIMEOUT_MS = 30_000;
const GIT_TIMEOUT_MS = 60_000;
const GIT_TIMEOUT_CODE = 124;
// After SIGTERM the process group gets this long to exit before SIGKILL.
const KILL_GRACE_MS = 2_000;
// After git exits, a grandchild (ssh) may still hold the pipes; output is not awaited past this.
const PIPE_DRAIN_MS = 250;
const STDERR_BRIEF_MAX = 300;

export interface GitResult {
  code: number;
  stdout: string;
  stderr: string;
}

/** Runs `git <args>` in `cwd`. `timeoutMs` kills the process and reports exit code 124. */
export type GitRunner = (
  args: string[],
  cwd: string,
  opts?: { timeoutMs?: number },
) => Promise<GitResult>;

/** The `code` of a Node-style system error, if `err` is one. */
function errnoCode(err: unknown): unknown {
  return err instanceof Error && "code" in err ? err.code : undefined;
}

const isMissing = (err: unknown): boolean => {
  const code = errnoCode(err);
  return code === "ENOENT" || code === "ENOTDIR";
};

const briefStderr = (stderr: string): string => stderr.trim().slice(0, STDERR_BRIEF_MAX);

/** Reads a pipe into a string without making the caller wait for EOF. */
function collect(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let text = "";
  const done = (async () => {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) return;
      text += decoder.decode(chunk.value, { stream: true });
    }
  })().catch(() => {});
  return {
    done,
    text: () => text,
    stop: () => void reader.cancel().catch(() => {}),
  };
}

/**
 * Runs git in its own process group. On timeout the whole group gets SIGTERM, then SIGKILL after a
 * grace period, so an ssh child of `git push` cannot outlive the call; the pipes are never waited
 * on past the exit of git, because a surviving grandchild would keep them open.
 */
export function createGitRunner(gitBinary = "git"): GitRunner {
  return async (args, cwd, opts) => {
    const timeoutMs = opts?.timeoutMs ?? GIT_TIMEOUT_MS;
    const proc = Bun.spawn([gitBinary, ...args], {
      cwd,
      stdout: "pipe",
      stderr: "pipe",
      detached: true,
    });
    const killGroup = (signal: NodeJS.Signals): void => {
      try {
        process.kill(-proc.pid, signal);
      } catch (err) {
        // ESRCH: the group is gone. EPERM: macOS reports a group whose only member is an
        // unreaped zombie leader that way; it is our own child, so nothing is left to signal.
        const code = errnoCode(err);
        if (code !== "ESRCH" && code !== "EPERM") throw err;
      }
    };
    const out = collect(proc.stdout);
    const err = collect(proc.stderr);

    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => resolve("timeout"), timeoutMs);
    });
    const first = await Promise.race([proc.exited, timeout]);
    clearTimeout(timer);

    let code = GIT_TIMEOUT_CODE;
    if (first === "timeout") {
      killGroup("SIGTERM");
      await Promise.race([proc.exited, Bun.sleep(KILL_GRACE_MS)]);
      killGroup("SIGKILL");
      await Promise.race([proc.exited, Bun.sleep(KILL_GRACE_MS)]);
    } else {
      code = first;
    }

    await Promise.race([Promise.all([out.done, err.done]), Bun.sleep(PIPE_DRAIN_MS)]);
    out.stop();
    err.stop();
    const stderr =
      first === "timeout"
        ? [err.text().trimEnd(), `git ${args[0]} timed out after ${timeoutMs}ms`]
            .filter(Boolean)
            .join("\n")
        : err.text();
    return { code, stdout: out.text(), stderr };
  };
}

export const bunGitRunner: GitRunner = createGitRunner();

export interface JournalDestinationOptions {
  /** Root of the brain git checkout; notes land in `<brainDir>/Inbox/`. */
  brainDir: string;
  /** Source of the note date, taken in the local time zone of the host. */
  clock?: Clock;
  git?: GitRunner;
  /** brain-sync's mkdir lock (`~/Library/Caches/brain-sync.lock` by default). */
  lockDir?: string;
  /** Extra attempts after the first try; the wait doubles from `lockBaseDelayMs`, capped at 10 s. */
  lockAttempts?: number;
  lockBaseDelayMs?: number;
  /** Bounds `git push`; a slow or failed push never fails the delivery. */
  pushTimeoutMs?: number;
}

const pad = (n: number): string => String(n).padStart(2, "0");

/** Local calendar date of the host, `YYYY-MM-DD`. */
function localDate(at: Date): string {
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`;
}

/** The first sentence of the transcript, clipped to ~60 chars on a word boundary. */
export function journalTitle(transcript: string): string {
  const text = transcript.replace(/\s+/g, " ").trim();
  const sentence = text.split(/(?<=[.!?])\s/)[0] ?? "";
  let title = sentence;
  if (title.length > TITLE_MAX) {
    const clipped = title.slice(0, TITLE_MAX + 1);
    const lastSpace = clipped.lastIndexOf(" ");
    title = lastSpace > 0 ? clipped.slice(0, lastSpace) : title.slice(0, TITLE_MAX);
  }
  title = title.replace(/[\s.,;:]+$/, "");
  return title === "" ? FALLBACK_TITLE : title;
}

/** Lowercase ASCII, German umlauts spelled out (ä → ae), other diacritics folded, hyphen separated. */
export function journalSlug(title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/ä/g, "ae")
    .replace(/ö/g, "oe")
    .replace(/ü/g, "ue")
    .replace(/ß/g, "ss")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, SLUG_MAX)
    .replace(/-+$/, "");
  return slug === "" ? FALLBACK_SLUG : slug;
}

function renderNote(params: { title: string; date: string; memoId: string; body: string }): string {
  return [
    "---",
    `title: ${JSON.stringify(params.title)}`,
    `date: ${params.date}`,
    "tags: [journal, iris]",
    "source: iris",
    `memo: ${params.memoId}`,
    "---",
    "",
    `${params.body.trim()}\n`,
  ].join("\n");
}

/** The `memo:` value of a note's frontmatter, if it has one. */
function memoOf(head: string): string | undefined {
  const frontmatter = head.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  return frontmatter?.[1]?.match(/^memo:\s*(\S+)\s*$/m)?.[1];
}

async function readMemoId(path: string): Promise<string | undefined> {
  try {
    return memoOf(await Bun.file(path).slice(0, FRONTMATTER_READ_BYTES).text());
  } catch (err) {
    // The note vanished between the listing and the read; anything else is a real failure.
    if (isMissing(err)) return undefined;
    throw err;
  }
}

/** The Inbox note already written for this memo, by frontmatter; a retry reuses it. */
async function findNoteOf(inboxDir: string, memoId: string): Promise<string | undefined> {
  const names = await readdir(inboxDir).catch((err: unknown): string[] => {
    if (isMissing(err)) return [];
    throw err;
  });
  // Only `.md` files: the `<name>.md.tmp-<pid>` of an interrupted write is not a note.
  for (const name of names.filter((n) => n.endsWith(".md")).toSorted()) {
    if ((await readMemoId(join(inboxDir, name))) === memoId) return name;
  }
  return undefined;
}

async function acquireLock(lockDir: string, attempts: number, baseDelayMs: number): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      await mkdir(lockDir);
      return;
    } catch (err) {
      if (errnoCode(err) !== "EEXIST") throw err;
      if (attempt >= attempts) {
        throw new Error(
          `journal: brain-sync lock is busy after ${attempts + 1} attempts (${lockDir})`,
          { cause: err },
        );
      }
      await Bun.sleep(Math.min(baseDelayMs * 2 ** attempt, LOCK_MAX_DELAY_MS));
    }
  }
}

/**
 * Writes the transcript as a note into the brain Inbox and commits it: under the brain-sync lock
 * (brain/docs/brain-access.md), `git add` + `git commit -- <file>` for this one path only, then a
 * bounded, fail-soft `git push`. A retry finds the note by its `memo:` frontmatter and neither
 * rewrites it nor commits it twice.
 */
export function createJournalDestination(opts: JournalDestinationOptions): Destination {
  const clock = opts.clock ?? systemClock;
  const git = opts.git ?? bunGitRunner;
  const lockDir = opts.lockDir ?? DEFAULT_LOCK_DIR;
  const inboxDir = join(opts.brainDir, INBOX);

  async function mustGit(args: string[]): Promise<GitResult> {
    const result = await git(args, opts.brainDir);
    if (result.code !== 0) {
      throw new Error(`journal: git ${args[0]} failed: ${briefStderr(result.stderr)}`);
    }
    return result;
  }

  /** Finds or writes this memo's note; returns its file name. */
  async function ensureNote(memoId: string, transcript: string, title: string): Promise<string> {
    const existing = await findNoteOf(inboxDir, memoId);
    if (existing) return existing;

    await mkdir(inboxDir, { recursive: true });
    const date = localDate(clock.now());
    const base = `${date}-${journalSlug(title)}`;
    let name = `${base}.md`;
    // A file at the plain name belongs to another memo (this memo has no note yet).
    if (await Bun.file(join(inboxDir, name)).exists()) {
      name = `${base}-${memoId.slice(0, 8)}.md`;
    }
    // Write aside, then link into place: a note is never visible half-written, and `link` never
    // overwrites whatever raced us to the name.
    const target = join(inboxDir, name);
    const tmp = `${target}.tmp-${process.pid}`;
    try {
      await writeFile(tmp, renderNote({ title, date, memoId, body: transcript }));
      await link(tmp, target);
    } finally {
      await rm(tmp, { force: true });
    }
    return name;
  }

  /** Under the brain-sync lock: the note on disk and committed. Returns its ref. */
  async function commitNote(
    memoId: string,
    transcript: string,
    title: string,
  ): Promise<{ ref: string; committed: boolean }> {
    await acquireLock(
      lockDir,
      opts.lockAttempts ?? DEFAULT_LOCK_ATTEMPTS,
      opts.lockBaseDelayMs ?? DEFAULT_LOCK_BASE_DELAY_MS,
    );
    try {
      const ref = `${INBOX}/${await ensureNote(memoId, transcript, title)}`;
      await mustGit(["add", "--", ref]);
      const pending = await mustGit(["status", "--porcelain", "--", ref]);
      if (pending.stdout.trim() === "") return { ref, committed: false };
      await mustGit(["commit", "-m", `journal: ${title}`, "--", ref]);
      return { ref, committed: true };
    } finally {
      await rm(lockDir, { recursive: true, force: true }).catch(() => {});
    }
  }

  return {
    deliver({ memoId, transcript }): Promise<Delivery> {
      return withSpan("journal.write", { memo_id: memoId, downstream: "journal" }, async (span) => {
        const { ref, committed } = await commitNote(memoId, transcript, journalTitle(transcript));
        span.setAttributes({ ref, committed });

        // Outside the lock: a slow remote must not hold brain-sync off. Fail-soft, brain-sync pushes later.
        const push = await git(["push"], opts.brainDir, {
          timeoutMs: opts.pushTimeoutMs ?? DEFAULT_PUSH_TIMEOUT_MS,
        });
        if (push.code !== 0) {
          log("journal.push_failed", {
            memo_id: memoId,
            code: push.code,
            stderr: briefStderr(push.stderr),
          });
        }

        log("journal.written", { memo_id: memoId, ref });
        return { ref, replyText: "" };
      });
    },
  };
}
