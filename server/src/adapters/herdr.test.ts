import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHerdrHerd } from "./herdr.js";

// A real unix socket server standing in for herdr: ndjson in, one response line out.

type Listener = ReturnType<typeof Bun.listen>;
let dir: string;
let server: Listener | undefined;

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "iris-herdr-"));
});
afterEach(async () => {
  server?.stop(true);
  server = undefined;
  await rm(dir, { recursive: true, force: true });
});

const socketPath = () => join(dir, "herdr.sock");

function serve(respond: (request: { id: string; method: string; params: unknown }) => string[]) {
  const requests: { id: string; method: string; params: unknown }[] = [];
  server = Bun.listen({
    unix: socketPath(),
    socket: {
      data(socket, chunk) {
        const request = JSON.parse(chunk.toString().trim()) as (typeof requests)[number];
        requests.push(request);
        for (const part of respond(request)) socket.write(part);
      },
    },
  });
  return requests;
}

const snapshot = {
  workspaces: [
    { workspace_id: "w1", label: "── TOOLING ──", number: 1 },
    { workspace_id: "w2", label: "iris", number: 2 },
    { workspace_id: "w3", label: "dotfiles (feat-x)", number: 3 },
  ],
  tabs: [
    { tab_id: "w1:t1", workspace_id: "w1", label: "1", agent_status: "unknown" },
    { tab_id: "w2:t1", workspace_id: "w2", label: "server", agent_status: "working" },
    { tab_id: "w2:t2", workspace_id: "w2", label: "1", agent_status: "done" },
    { tab_id: "w3:t4", workspace_id: "w3", label: "wave", agent_status: "mystery" },
    { tab_id: "w9:t1", workspace_id: "w9", label: "orphan", agent_status: "idle" },
  ],
};

const reply = (id: string) =>
  `${JSON.stringify({ id, result: { type: "session_snapshot", snapshot } })}\n`;

describe("herdr herd", () => {
  it("sends session.snapshot and maps real workspaces' tabs", async () => {
    const requests = serve((r) => [reply(r.id)]);
    const tabs = await createHerdrHerd({ socketPath: socketPath() }).snapshot();

    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({ method: "session.snapshot", params: {} });
    expect(tabs).toEqual([
      { id: "w2:t1", repo: "iris", label: "server", agentState: "working", lastActivity: null },
      { id: "w2:t2", repo: "iris", label: "1", agentState: "done", lastActivity: null },
      {
        id: "w3:t4",
        repo: "dotfiles (feat-x)",
        label: "wave",
        agentState: "unknown",
        lastActivity: null,
      },
    ]);
  });

  it("reassembles a response that arrives in pieces", async () => {
    serve((r) => {
      const line = reply(r.id);
      const mid = Math.floor(line.length / 2);
      return [line.slice(0, mid), line.slice(mid)];
    });
    const tabs = await createHerdrHerd({ socketPath: socketPath() }).snapshot();
    expect(tabs.map((t) => t.id)).toEqual(["w2:t1", "w2:t2", "w3:t4"]);
  });

  it("is unavailable when nothing listens on the socket", async () => {
    await expect(createHerdrHerd({ socketPath: socketPath() }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
    });
  });

  it("is unavailable when herdr answers with an error", async () => {
    serve((r) => [`${JSON.stringify({ id: r.id, error: { code: "boom" } })}\n`]);
    await expect(createHerdrHerd({ socketPath: socketPath() }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
      message: "herdr: unexpected session.snapshot response",
    });
  });

  it("is unavailable when the answer is not JSON", async () => {
    serve(() => ["not json\n"]);
    await expect(createHerdrHerd({ socketPath: socketPath() }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
    });
  });

  it("is unavailable when herdr hangs up without answering", async () => {
    server = Bun.listen({
      unix: socketPath(),
      socket: {
        data(socket) {
          socket.end();
        },
      },
    });
    await expect(createHerdrHerd({ socketPath: socketPath() }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
    });
  });

  it("gives up on a silent socket after the timeout", async () => {
    serve(() => []);
    const started = Date.now();
    const error = await createHerdrHerd({ socketPath: socketPath(), timeoutMs: 100 })
      .snapshot()
      .catch((e: unknown) => e);
    expect(error).toMatchObject({ code: "unavailable", message: "herdr: no answer within 100 ms" });
    expect(Date.now() - started).toBeLessThan(2000);
  });
});
