import { z } from "zod";
import { MemoError } from "../memo/errors.js";
import { createKeyedQueue, KeyedQueueFull } from "../memo/keyed-queue.js";
import { TabGoneError, type Delivery, type Destination } from "../ports/destination.js";
import { AGENT_STATES, type AgentState, type Herd, type HerdTab } from "../ports/herd.js";
import { withSpan } from "../telemetry/otel.js";

// A hang guard: a snapshot answers in milliseconds, a wedged herdr must not hold a request.
const TIMEOUT_MS = 5_000;
// A workspace the user names `── GROUP ──` is a sidebar separator, not a repo.
const SEPARATOR_PREFIX = "── ";
// Deliveries in line on one pane (the running one included). Each call is bounded by `TIMEOUT_MS`, but a pane that keeps
// answering slowly would otherwise let memos pile up behind it without limit.
const MAX_PANE_QUEUE = 8;

export interface HerdrHerdOptions {
  socketPath: string;
  timeoutMs?: number;
}

export interface HerdrDestinationOptions extends HerdrHerdOptions {
  /** Deliveries allowed in line on one pane; past it a delivery fails at once, not transient. */
  maxPaneQueue?: number;
}

/**
 * Verified against a live herdr 0.9.3 (protocol 22) socket, read-only. Newline-delimited JSON, ONE
 * request per connection (only `events.subscribe` keeps a connection open, a second request on the
 * same socket dies with EPIPE):
 *
 *   -> {"id":"<any>","method":"session.snapshot","params":{}}\n
 *   <- {"id":"<same>","result":{"type":"session_snapshot","snapshot":{
 *        "version","protocol","focused_workspace_id","focused_tab_id","focused_pane_id",
 *        "workspaces":[{"workspace_id","number","label","focused","pane_count","tab_count",
 *                       "active_tab_id","agent_status","worktree"?}],
 *        "tabs":[{"tab_id","workspace_id","number","label","focused","pane_count","agent_status"}],
 *        "panes":[...], "layouts":[...], "agents":[...]}}}\n
 *      or {"id","error":{...}}\n
 *
 * `agent_status` is idle | working | blocked | done | unknown. The snapshot carries no timestamps,
 * only a `state_change_seq` counter on agents, so `lastActivity` is always null.
 *
 * A HerdTab is one tab of a real workspace: `repo` is the workspace label, `label` the tab label.
 *
 * Delivery (request shapes from `herdr api schema --json`, protocol 22; the snapshot rows below read from a
 * live socket, the two writes exercised once against a scratch tab that was closed afterwards). The
 * snapshot's `panes` are `{pane_id, tab_id, workspace_id, agent_status, ...}` and its `agents` are the
 * panes herdr recognised an agent in, `{pane_id, tab_id, agent, interactive_ready, ...}`:
 *
 *   -> {"id","method":"pane.send_text","params":{"pane_id":"w2:p1","text":"<transcript>"}}\n
 *   -> {"id","method":"pane.send_keys","params":{"pane_id":"w2:p1","keys":["enter"]}}\n
 *   <- {"id","result":{...}}\n   or   {"id","error":{"code","message"}}\n
 *
 * `send_text` types the text literally; the separate Enter submits it, so a multi-line transcript is one
 * prompt, not several. The agent pane of a tab is its `agents` entry; a tab without one but with a single
 * pane gets that pane; anything else is ambiguous and not delivered.
 */
const Snapshot = z.object({
  workspaces: z.array(z.object({ workspace_id: z.string(), label: z.string() })),
  tabs: z.array(
    z.object({
      tab_id: z.string(),
      workspace_id: z.string(),
      label: z.string(),
      agent_status: z.string(),
    }),
  ),
  panes: z.array(z.object({ pane_id: z.string(), tab_id: z.string() })).default([]),
  agents: z.array(z.object({ pane_id: z.string(), tab_id: z.string() })).default([]),
});
type SnapshotData = z.infer<typeof Snapshot>;

const Response = z.object({
  result: z.unknown().optional(),
  error: z.object({ code: z.string().optional() }).passthrough().optional(),
});

const KNOWN_STATES: ReadonlySet<string> = new Set(AGENT_STATES);
const toState = (status: string): AgentState =>
  KNOWN_STATES.has(status) ? (status as AgentState) : "unknown";

const unavailable = (detail: string) => new MemoError("unavailable", `herdr: ${detail}`);

/** Sends one request and resolves with the first response line, parsed. */
function request(params: {
  socketPath: string;
  method: string;
  params?: Record<string, unknown>;
  timeoutMs: number;
}): Promise<unknown> {
  const { socketPath, method, timeoutMs } = params;
  return new Promise((resolve, reject) => {
    const decoder = new TextDecoder();
    let buffer = "";
    let socket: { end(): void } | undefined;
    let settled = false;
    const settle = (outcome: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket?.end();
      outcome();
    };
    const fail = (detail: string) => settle(() => reject(unavailable(detail)));
    const timer = setTimeout(() => fail(`no answer within ${timeoutMs} ms`), timeoutMs);

    Bun.connect({
      unix: socketPath,
      socket: {
        open(s) {
          if (settled) {
            s.end();
            return;
          }
          socket = s;
          s.write(
            `${JSON.stringify({ id: crypto.randomUUID(), method, params: params.params ?? {} })}\n`,
          );
        },
        data(_s, chunk) {
          buffer += decoder.decode(chunk, { stream: true });
          const end = buffer.indexOf("\n");
          if (end < 0) return;
          try {
            const line = JSON.parse(buffer.slice(0, end)) as unknown;
            settle(() => resolve(line));
          } catch {
            fail("unparseable response");
          }
        },
        close: () => fail("connection closed before a response"),
        error: (_s, err) => fail(err.message),
        connectError: (_s, err) => fail(err.message),
      },
    }).catch((err: unknown) => fail(err instanceof Error ? err.message : String(err)));
  });
}

/** herdr answered `{error: {code: "pane_not_found"}}` (verified against 0.9.3): the pane closed since the snapshot. */
class NotFoundAnswer extends Error {}

/** One request; resolves with `result`, throws `unavailable` on an `error` answer or an off-schema line. */
async function call(params: {
  socketPath: string;
  method: string;
  params?: Record<string, unknown>;
  timeoutMs: number;
}): Promise<unknown> {
  const parsed = Response.safeParse(await request(params));
  if (!parsed.success) throw unavailable(`unexpected ${params.method} response`);
  const { error } = parsed.data;
  if (error !== undefined) {
    if (error.code?.endsWith("_not_found")) throw new NotFoundAnswer(params.method);
    throw unavailable(`${params.method} failed: ${JSON.stringify(error)}`);
  }
  return parsed.data.result;
}

async function readSnapshot(opts: {
  socketPath: string;
  timeoutMs: number;
}): Promise<SnapshotData> {
  const result = await call({ ...opts, method: "session.snapshot" });
  const parsed = z.object({ snapshot: Snapshot }).safeParse(result);
  if (!parsed.success) throw unavailable("unexpected session.snapshot response");
  return parsed.data.snapshot;
}

export function createHerdrHerd(opts: HerdrHerdOptions): Herd {
  const { socketPath, timeoutMs = TIMEOUT_MS } = opts;

  return {
    snapshot(): Promise<HerdTab[]> {
      return withSpan("herdr.snapshot", { downstream: "herdr" }, async () => {
        const { workspaces, tabs } = await readSnapshot({ socketPath, timeoutMs });
        const repos = new Map(
          workspaces
            .filter((w) => !w.label.startsWith(SEPARATOR_PREFIX))
            .map((w) => [w.workspace_id, w.label]),
        );
        return tabs.flatMap((tab) => {
          const repo = repos.get(tab.workspace_id);
          if (repo === undefined) return [];
          return [
            {
              id: tab.tab_id,
              repo,
              label: tab.label,
              agentState: toState(tab.agent_status),
              lastActivity: null,
            },
          ];
        });
      });
    },
  };
}

/** The pane that takes the memo: the tab's agent, else its only pane; null when the tab is gone or ambiguous. */
function agentPane(snapshot: SnapshotData, tab: string): { pane: string } | "gone" | "ambiguous" {
  if (!snapshot.tabs.some((t) => t.tab_id === tab)) return "gone";
  const agent = snapshot.agents.find((a) => a.tab_id === tab);
  if (agent) return { pane: agent.pane_id };
  const panes = snapshot.panes.filter((p) => p.tab_id === tab);
  const [only] = panes;
  if (only && panes.length === 1) return { pane: only.pane_id };
  return "ambiguous";
}

/**
 * Types the transcript into the agent pane of a tab and presses Enter. The reply is not awaited: the
 * agent answers in its own terminal, so `replyText` is empty. A tab missing from the live snapshot, or a
 * pane herdr no longer finds when writing (the tab closed in between), throws `TabGoneError`; any other
 * failure is `unavailable`, which fails the step and can be retried. Deliveries to one pane are serialised,
 * so two memos never interleave their text and Enter. At most `maxPaneQueue` (8) deliveries
 * are in line on a pane; the next fails at once as `unavailable` ("queue is full"), which is not transient, so the step
 * fails after one try and `POST /retry` queues it again.
 */
export function createHerdrDestination(opts: HerdrDestinationOptions): Destination {
  const { socketPath, timeoutMs = TIMEOUT_MS, maxPaneQueue = MAX_PANE_QUEUE } = opts;
  const serialized = createKeyedQueue({ maxDepth: maxPaneQueue });

  return {
    deliver({ transcript, tab }): Promise<Delivery> {
      return withSpan("herdr.deliver", { downstream: "herdr" }, async () => {
        if (tab === undefined) throw unavailable("deliver needs a tab");
        const snapshot = await readSnapshot({ socketPath, timeoutMs });
        const target = agentPane(snapshot, tab);
        if (target === "gone") throw new TabGoneError(tab);
        if (target === "ambiguous") throw unavailable(`tab ${tab} has no single agent pane`);

        const pane_id = target.pane;
        await serialized(pane_id, async () => {
          await call({
            socketPath,
            timeoutMs,
            method: "pane.send_text",
            params: { pane_id, text: transcript },
          });
          await call({
            socketPath,
            timeoutMs,
            method: "pane.send_keys",
            params: { pane_id, keys: ["enter"] },
          });
        }).catch((err: unknown) => {
          if (err instanceof NotFoundAnswer) throw new TabGoneError(tab);
          if (err instanceof KeyedQueueFull) {
            throw new MemoError(
              "unavailable",
              `herdr pane ${pane_id} queue is full: ${err.depth} deliveries already in line`,
            );
          }
          throw err;
        });
        return { ref: tab, replyText: "" };
      });
    },
  };
}
