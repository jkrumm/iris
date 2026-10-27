import { mkdir, readdir, rm, writeFile } from "node:fs/promises";
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

export const bunGitRunner: GitRunner = async (args, cwd, opts) => {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, opts?.timeoutMs ?? GIT_TIMEOUT_MS);
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    return timedOut
      ? { code: GIT_TIMEOUT_CODE, stdout, stderr: `${stderr}timed out after ${opts?.timeoutMs}ms` }
      : { code, stdout, stderr };
  } finally {
    clearTimeout(timer);
  }
};

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
    .replace(/[̀-ͯ]/g, "")
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
  const head = await Bun.file(path).slice(0, FRONTMATTER_READ_BYTES).text();
  return memoOf(head);
}

/** The Inbox note already written for this memo, by frontmatter; a retry reuses it. */
async function findNoteOf(inboxDir: string, memoId: string): Promise<string | undefined> {
  const names = await readdir(inboxDir).catch(() => [] as string[]);
  for (const name of names.filter((n) => n.endsWith(".md")).toSorted()) {
    if ((await readMemoId(join(inboxDir, name)).catch(() => undefined)) === memoId) return name;
  }
  return undefined;
}

async function acquireLock(lockDir: string, attempts: number, baseDelayMs: number): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      await mkdir(lockDir);
      return;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
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
      throw new Error(`journal: git ${args[0]} failed: ${result.stderr.trim().slice(0, 300)}`);
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
    // `wx`: never overwrite someone else's note, whatever raced us.
    await writeFile(join(inboxDir, name), renderNote({ title, date, memoId, body: transcript }), {
      flag: "wx",
    });
    return name;
  }

  return {
    deliver({ memoId, transcript }): Promise<Delivery> {
      return withSpan("journal.write", { memo_id: memoId, downstream: "journal" }, async (span) => {
        const title = journalTitle(transcript);

        await acquireLock(
          lockDir,
          opts.lockAttempts ?? DEFAULT_LOCK_ATTEMPTS,
          opts.lockBaseDelayMs ?? DEFAULT_LOCK_BASE_DELAY_MS,
        );
        try {
          const name = await ensureNote(memoId, transcript, title);
          const ref = `${INBOX}/${name}`;
          span.setAttributes({ ref });

          await mustGit(["add", "--", ref]);
          const pending = await mustGit(["status", "--porcelain", "--", ref]);
          if (pending.stdout.trim() === "") {
            span.setAttributes({ committed: false });
          } else {
            await mustGit(["commit", "-m", `journal: ${title}`, "--", ref]);
            span.setAttributes({ committed: true });
          }

          const push = await git(["push"], opts.brainDir, {
            timeoutMs: opts.pushTimeoutMs ?? DEFAULT_PUSH_TIMEOUT_MS,
          });
          if (push.code !== 0) {
            log("journal.push_failed", {
              memo_id: memoId,
              code: push.code,
              stderr: push.stderr.trim().slice(0, 300),
            });
          }

          log("journal.written", { memo_id: memoId, ref });
          return { ref, replyText: "" };
        } finally {
          await rm(lockDir, { recursive: true, force: true }).catch(() => {});
        }
      });
    },
  };
}
