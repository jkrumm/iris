import { existsSync } from "node:fs";
import { basename } from "node:path";
import { z } from "zod";
import { MemoError } from "../memo/errors.js";
import { createKeyedQueue, KeyedQueueFull } from "../memo/keyed-queue.js";
import { TabGoneError, type Delivery, type Destination } from "../ports/destination.js";
import { AGENT_STATES, type AgentState, type Herd, type HerdTab } from "../ports/herd.js";
import { withSpan } from "../telemetry/otel.js";

// The herdr-core world (`hc`, TDD D17 retirement of classic herdr). Beside `herdr.ts`, which still serves the classic
// socket until it is gone; `herdr-worlds.ts` merges the two.

// A listing answers in milliseconds, a wedged core must not hold a request.
const LIST_TIMEOUT_MS = 5_000;
// `terminal.send` pastes, then waits for ~3 s of typing quiet before Enter (and reports whether the agent went
// working), so it legitimately takes seconds.
const SEND_TIMEOUT_MS = 30_000;
const MAX_TERMINAL_QUEUE = 8;

/** A tab is a `herdr.tab` label shared by the terminals the app puts in it. */
const TAB_LABEL = "herdr.tab";
/** The app writes `<space name> / <tab name>` into this label when it adopts a terminal. */
const WHERE_LABEL = "where";
const WHERE_SEPARATOR = " / ";
const SEPARATOR_PREFIX = "── ";

/**
 * Verified against hc 0.1.15 (`hc schema`, a read-only `terminal.list` on the mini's launchd core; the send path
 * against a scratch core). `hc connect` speaks JSON-RPC 2.0, one JSON object per line, on stdin/stdout:
 *
 *   -> {"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{"labels":{"herdr.tab":"tb…"}}}\n
 *   <- {"jsonrpc":"2.0","id":1,"result":{"terminals":[{"address":"t3","labels":{…},"status":null|{"app","state"},
 *        "cwd","state":"live",…}],"hidden_finished":0,"machines":[]}}\n
 *   -> {"jsonrpc":"2.0","id":2,"method":"terminal.send","params":{"terminal":"t3","text":"…"}}\n   (paste + Enter)
 *   <- {"id":2,"result":{"turn":4,"started":true,"status":"working"}}  or  {"id":2,"error":{"code":-32000,"data":{"kind":"not_found"|"finished"|"blocked"|…},"message"}}
 *
 * `status` is the program's own OSC 7501 report (null for a plain shell): state idle | working | blocked | done | error.
 * A linked machine's terminals come back as `machine/t7`; iris serves the mini only, so those are skipped.
 */
export interface HcTransport {
  /** One request over a fresh `hc connect`; resolves with `result`, throws {@link HcError} on an `error` answer and `MemoError("unavailable")` when the core cannot be reached. */
  call(params: {
    method: string;
    params?: Record<string, unknown>;
    timeoutMs: number;
  }): Promise<unknown>;
}

/** The core answered an `error`; `kind` is its `data.kind` (`not_found`, `finished`, `blocked`, …). */
export class HcError extends Error {
  constructor(
    readonly method: string,
    readonly kind: string,
    message: string,
  ) {
    super(`${method}: ${message}`);
    this.name = "HcError";
  }
}

const unavailable = (detail: string) => new MemoError("unavailable", `herdr-core: ${detail}`);

const Answer = z.object({
  id: z.unknown().optional(),
  result: z.unknown().optional(),
  error: z
    .object({
      message: z.string().optional(),
      data: z.object({ kind: z.string().optional() }).passthrough().optional(),
    })
    .passthrough()
    .optional(),
});

export interface HcTransportOptions {
  /** The `hc` binary. */
  bin: string;
  /**
   * The core's socket (`~/.local/state/herdr-core/default/default.sock`), required. Any `hc` call starts a core when none
   * runs, and a core born under iris would hand iris's environment to every terminal: when this file is missing the
   * transport refuses without spawning, and the child gets `HC_SOCKET` as its whole environment. A core that stops between
   * the check and the spawn can still be replaced by this child (`hc` has no flag against it); the LaunchAgent's
   * KeepAlive makes that window a restart, and the scrubbed environment keeps iris's secrets out of it.
   */
  socket: string;
}

/** Per-request `hc connect`: spawn, one line in, read until the matching answer, kill. */
export function createHcTransport(opts: HcTransportOptions): HcTransport {
  let nextId = 1;
  return {
    async call({ method, params, timeoutMs }) {
      if (!existsSync(opts.socket)) {
        throw unavailable("no core is running");
      }
      const id = nextId++;
      // hc finds the core by `HC_SOCKET` alone (verified with `env -i`).
      const env = { HC_SOCKET: opts.socket };
      let proc: ReturnType<typeof Bun.spawn>;
      try {
        proc = Bun.spawn([opts.bin, "connect"], {
          stdin: "pipe",
          stdout: "pipe",
          stderr: "ignore",
          env,
        });
      } catch (err) {
        throw unavailable(err instanceof Error ? err.message : String(err));
      }
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        proc.kill();
      }, timeoutMs);
      try {
        const stdin = proc.stdin as import("bun").FileSink;
        stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params: params ?? {} })}\n`);
        await stdin.flush();
        const decoder = new TextDecoder();
        let buffer = "";
        for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
          buffer += decoder.decode(chunk, { stream: true });
          for (let end = buffer.indexOf("\n"); end >= 0; end = buffer.indexOf("\n")) {
            const line = buffer.slice(0, end);
            buffer = buffer.slice(end + 1);
            const answer = parseAnswer(line, id);
            if (answer === undefined) continue;
            if (answer.error !== undefined) {
              throw new HcError(
                method,
                answer.error.data?.kind ?? "error",
                answer.error.message ?? "failed",
              );
            }
            if (!answer.hasResult) throw unavailable(`${method} answered without a result`);
            return answer.result;
          }
        }
        throw unavailable(
          timedOut ? `no answer within ${timeoutMs} ms` : "connection closed before an answer",
        );
      } finally {
        clearTimeout(timer);
        proc.kill();
      }
    },
  };
}

/** The answer to request `id`; undefined for any other line (heartbeats, news, a different id). */
function parseAnswer(
  line: string,
  id: number,
): (z.infer<typeof Answer> & { hasResult: boolean }) | undefined {
  let json: unknown;
  try {
    json = JSON.parse(line);
  } catch {
    return undefined;
  }
  const parsed = Answer.safeParse(json);
  if (!parsed.success || parsed.data.id !== id) return undefined;
  return {
    ...parsed.data,
    hasResult: typeof json === "object" && json !== null && "result" in json,
  };
}

const Terminal = z.object({
  address: z.string(),
  cwd: z.string().optional(),
  labels: z.record(z.string(), z.string()).default({}),
  status: z.object({ state: z.string() }).passthrough().nullable().default(null),
});
type HcTerminal = z.infer<typeof Terminal>;
const SendResult = z.object({ turn: z.number() }).passthrough();
const ListResult = z.object({ terminals: z.array(Terminal) });

const KNOWN_STATES: ReadonlySet<string> = new Set(AGENT_STATES);
const toState = (state: string | undefined): AgentState =>
  state !== undefined && KNOWN_STATES.has(state) ? (state as AgentState) : "unknown";

/** Most urgent first: what the tab's single status dot shows when it holds several programs. */
const URGENCY: readonly AgentState[] = ["blocked", "working", "done", "idle", "unknown"];

async function listTerminals(
  transport: HcTransport,
  labels: Record<string, string>,
): Promise<HcTerminal[]> {
  const result = await transport
    .call({ method: "terminal.list", params: { labels }, timeoutMs: LIST_TIMEOUT_MS })
    .catch((err: unknown) => {
      if (err instanceof HcError) throw unavailable(`${err.message} (${err.kind})`);
      throw err;
    });
  const parsed = ListResult.safeParse(result);
  if (!parsed.success) throw unavailable("unexpected terminal.list response");
  // `machine/t7` is a linked machine's terminal: not this host's, never a destination.
  return parsed.data.terminals.filter((t) => !t.address.includes("/"));
}

/** The program that takes the memo: the tab's one agent (a terminal that reports status), else its only terminal. */
function agentOf(terminals: HcTerminal[]): HcTerminal | "ambiguous" {
  const agents = terminals.filter((t) => t.status !== null);
  const [agent] = agents;
  if (agent && agents.length === 1) return agent;
  const [only] = terminals;
  if (only && terminals.length === 1) return only;
  return "ambiguous";
}

/** `<space> / <tab>` from the app's `where` label; without it the cwd names the repo. */
function placeOf(terminals: HcTerminal[], tab: string): { repo: string; label: string } {
  for (const t of terminals) {
    const where = t.labels[WHERE_LABEL];
    const at = where?.lastIndexOf(WHERE_SEPARATOR) ?? -1;
    if (where !== undefined && at > 0) {
      return { repo: where.slice(0, at), label: where.slice(at + WHERE_SEPARATOR.length) };
    }
  }
  const cwd = terminals.find((t) => t.cwd !== undefined)?.cwd;
  return { repo: cwd === undefined ? tab : basename(cwd), label: "1" };
}

/**
 * Live tabs of the hc world: terminals grouped by their `herdr.tab` label (an unlabelled terminal is a hidden worker
 * or a plain `hc run`, never a destination). The tab id is the label's value, so a memo routed to it survives the
 * terminal being replaced by `keep`.
 */
export function createHcHerd(opts: { transport: HcTransport }): Herd {
  return {
    snapshot(): Promise<HerdTab[]> {
      return withSpan("hc.snapshot", { downstream: "herdr-core" }, async () => {
        const terminals = await listTerminals(opts.transport, {});
        const byTab = new Map<string, HcTerminal[]>();
        for (const t of terminals) {
          const tab = t.labels[TAB_LABEL];
          if (tab === undefined) continue;
          byTab.set(tab, [...(byTab.get(tab) ?? []), t]);
        }
        return [...byTab].flatMap(([tab, members]) => {
          const place = placeOf(members, tab);
          if (place.repo.startsWith(SEPARATOR_PREFIX)) return [];
          const states = members.map((t) => toState(t.status?.state));
          const agentState = URGENCY.find((s) => states.includes(s)) ?? "unknown";
          return [{ id: tab, ...place, agentState, lastActivity: null }];
        });
      });
    },
  };
}

export interface HcDestinationOptions {
  transport: HcTransport;
  /** Deliveries allowed in line on one terminal; past it a delivery fails at once, not transient. */
  maxTerminalQueue?: number;
}

/**
 * Pastes the transcript into the tab's agent terminal and presses Enter (`terminal.send`, which waits for the typing
 * pause and refuses a program blocked on a dialog). The reply is not awaited: the agent answers in its terminal, so
 * `replyText` is empty. A tab with no live terminal, or one that ended between the listing and the send, throws
 * `TabGoneError`; a blocked agent, an ambiguous tab, a full line and anything else are `unavailable` (the step fails,
 * `POST /retry` queues it again). Deliveries to one terminal are serialised.
 */
export function createHcDestination(opts: HcDestinationOptions): Destination {
  const { transport, maxTerminalQueue = MAX_TERMINAL_QUEUE } = opts;
  const serialized = createKeyedQueue({ maxDepth: maxTerminalQueue });

  return {
    deliver({ transcript, tab }): Promise<Delivery> {
      return withSpan("hc.deliver", { downstream: "herdr-core" }, async () => {
        if (tab === undefined) throw unavailable("deliver needs a tab");
        const terminals = await listTerminals(transport, { [TAB_LABEL]: tab });
        if (terminals.length === 0) throw new TabGoneError(tab);
        const target = agentOf(terminals);
        if (target === "ambiguous") throw unavailable(`tab ${tab} has no single agent terminal`);

        const terminal = target.address;
        await serialized(terminal, async () => {
          // The wait in line can be long: the terminal may have ended, or been adopted by another tab, since the listing.
          const current = await listTerminals(transport, { [TAB_LABEL]: tab });
          if (!current.some((t) => t.address === terminal)) throw new TabGoneError(tab);
          const sent = SendResult.safeParse(
            await transport.call({
              method: "terminal.send",
              params: { terminal, text: transcript },
              timeoutMs: SEND_TIMEOUT_MS,
            }),
          );
          if (!sent.success) throw unavailable("unexpected terminal.send response");
        }).catch((err: unknown) => {
          if (err instanceof HcError) {
            if (err.kind === "not_found" || err.kind === "finished") throw new TabGoneError(tab);
            throw unavailable(`${err.message} (${err.kind})`);
          }
          if (err instanceof KeyedQueueFull) {
            throw unavailable(
              `terminal ${terminal} queue is full: ${err.depth} deliveries already in line`,
            );
          }
          throw err;
        });
        return { ref: tab, replyText: "" };
      });
    },
  };
}
