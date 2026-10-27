import { z } from "zod";
import { MemoError } from "../memo/errors.js";
import { AGENT_STATES, type AgentState, type Herd, type HerdTab } from "../ports/herd.js";
import { withSpan } from "../telemetry/otel.js";

// A hang guard: a snapshot answers in milliseconds, a wedged herdr must not hold a request.
const TIMEOUT_MS = 5_000;
// A workspace the user names `── GROUP ──` is a sidebar separator, not a repo.
const SEPARATOR_PREFIX = "── ";

export interface HerdrHerdOptions {
  socketPath: string;
  timeoutMs?: number;
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
 */
const Snapshot = z.object({
  result: z.object({
    snapshot: z.object({
      workspaces: z.array(z.object({ workspace_id: z.string(), label: z.string() })),
      tabs: z.array(
        z.object({
          tab_id: z.string(),
          workspace_id: z.string(),
          label: z.string(),
          agent_status: z.string(),
        }),
      ),
    }),
  }),
});

const KNOWN_STATES: ReadonlySet<string> = new Set(AGENT_STATES);
const toState = (status: string): AgentState =>
  KNOWN_STATES.has(status) ? (status as AgentState) : "unknown";

const unavailable = (detail: string) => new MemoError("unavailable", `herdr: ${detail}`);

/** Sends one request and resolves with the first response line, parsed. */
function request(params: {
  socketPath: string;
  method: string;
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
          s.write(`${JSON.stringify({ id: crypto.randomUUID(), method, params: {} })}\n`);
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

export function createHerdrHerd(opts: HerdrHerdOptions): Herd {
  const { socketPath, timeoutMs = TIMEOUT_MS } = opts;

  return {
    snapshot(): Promise<HerdTab[]> {
      return withSpan("herdr.snapshot", { downstream: "herdr" }, async () => {
        const raw = await request({ socketPath, method: "session.snapshot", timeoutMs });
        const parsed = Snapshot.safeParse(raw);
        if (!parsed.success) throw unavailable("unexpected session.snapshot response");

        const { workspaces, tabs } = parsed.data.result.snapshot;
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
