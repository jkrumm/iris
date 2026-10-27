import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TabGoneError } from "../ports/destination.js";
import { createHerdrDestination, createHerdrHerd } from "./herdr.js";

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
  panes: [
    { pane_id: "w2:p1", tab_id: "w2:t1" },
    { pane_id: "w2:p2", tab_id: "w2:t1" },
    { pane_id: "w2:p3", tab_id: "w2:t2" },
    { pane_id: "w3:p1", tab_id: "w3:t4" },
    { pane_id: "w3:p2", tab_id: "w3:t4" },
  ],
  agents: [{ pane_id: "w2:p2", tab_id: "w2:t1" }],
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
      message: expect.stringContaining("session.snapshot failed"),
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

const ok = (id: string) => `${JSON.stringify({ id, result: { type: "ok" } })}\n`;

/** Answers the snapshot, then every write with ok (or the given response). */
function serveWrites(write: (r: { id: string; method: string }) => string = (r) => ok(r.id)) {
  return serve((r) => [r.method === "session.snapshot" ? reply(r.id) : write(r)]);
}

const deliver = (tab: string | undefined, transcript = "run the tests\nthen push") =>
  createHerdrDestination({ socketPath: socketPath(), timeoutMs: 500 }).deliver({
    memoId: "memo-1",
    transcript,
    ...(tab !== undefined && { tab }),
  });

describe("herdr destination", () => {
  it("types the transcript into the agent pane, then presses Enter", async () => {
    const requests = serveWrites();
    expect(await deliver("w2:t1")).toEqual({ ref: "w2:t1", replyText: "" });
    expect(requests.map(({ method, params }) => ({ method, params }))).toEqual([
      { method: "session.snapshot", params: {} },
      { method: "pane.send_text", params: { pane_id: "w2:p2", text: "run the tests\nthen push" } },
      { method: "pane.send_keys", params: { pane_id: "w2:p2", keys: ["enter"] } },
    ]);
  });

  it("uses the only pane of a tab without a recognised agent", async () => {
    const requests = serveWrites();
    await deliver("w2:t2");
    expect(requests[1]).toMatchObject({ params: { pane_id: "w2:p3" } });
  });

  it("does not guess between several panes without an agent", async () => {
    const requests = serveWrites();
    await expect(deliver("w3:t4")).rejects.toMatchObject({ code: "unavailable" });
    expect(requests.map((r) => r.method)).toEqual(["session.snapshot"]);
  });

  it("throws TabGoneError for a tab that is not in the snapshot, sending nothing", async () => {
    const requests = serveWrites();
    const error = await deliver("w2:tX").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TabGoneError);
    expect(error).toMatchObject({ tab: "w2:tX", message: "tab w2:tX is gone" });
    expect(requests.map((r) => r.method)).toEqual(["session.snapshot"]);
  });

  it("is unavailable without a tab", async () => {
    const requests = serveWrites();
    await expect(deliver(undefined)).rejects.toMatchObject({ code: "unavailable" });
    expect(requests).toEqual([]);
  });

  it("does not press Enter when the text was refused", async () => {
    const requests = serveWrites(
      (r) => `${JSON.stringify({ id: r.id, error: { code: "boom" } })}\n`,
    );
    await expect(deliver("w2:t1")).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("pane.send_text failed"),
    });
    expect(requests.map((r) => r.method)).toEqual(["session.snapshot", "pane.send_text"]);
  });

  it.each(["pane.send_text", "pane.send_keys"])(
    "maps a pane_not_found answer from %s to TabGoneError",
    async (method) => {
      serveWrites((r) =>
        r.method === method
          ? `${JSON.stringify({ id: r.id, error: { code: "pane_not_found", message: "gone" } })}\n`
          : ok(r.id),
      );
      const error = await deliver("w2:t1").catch((e: unknown) => e);
      expect(error).toBeInstanceOf(TabGoneError);
      expect(error).toMatchObject({ tab: "w2:t1" });
    },
  );

  it("keeps one delivery's text and Enter contiguous when two memos target the same pane", async () => {
    const log: string[] = [];
    server = Bun.listen({
      unix: socketPath(),
      socket: {
        data(socket, chunk) {
          const r = JSON.parse(chunk.toString().trim()) as {
            id: string;
            method: string;
            params: { text?: string };
          };
          if (r.method === "session.snapshot") return void socket.write(reply(r.id));
          log.push(r.method === "pane.send_text" ? `text:${r.params.text}` : "enter");
          // Slow writes: an unserialised second delivery would slip its text in before the first Enter.
          setTimeout(() => socket.write(ok(r.id)), 30);
        },
      },
    });
    const deliverTo = createHerdrDestination({ socketPath: socketPath(), timeoutMs: 2000 });
    await Promise.all(
      ["first", "second"].map((transcript) =>
        deliverTo.deliver({ memoId: transcript, transcript, tab: "w2:t1" }),
      ),
    );
    expect(log).toEqual(["text:first", "enter", "text:second", "enter"]);
  });

  it("does not hold up a pane behind a failed delivery", async () => {
    let failNext = true;
    serveWrites((r) => {
      if (r.method === "pane.send_text" && failNext) {
        failNext = false;
        return `${JSON.stringify({ id: r.id, error: { code: "boom" } })}\n`;
      }
      return ok(r.id);
    });
    const deliverTo = createHerdrDestination({ socketPath: socketPath(), timeoutMs: 2000 });
    const results = await Promise.allSettled(
      ["a", "b"].map((transcript) =>
        deliverTo.deliver({ memoId: transcript, transcript, tab: "w2:t1" }),
      ),
    );
    expect(results.map((r) => r.status)).toEqual(["rejected", "fulfilled"]);
  });

  it("is unavailable when nothing listens, and gives up on a silent socket", async () => {
    await expect(deliver("w2:t1")).rejects.toMatchObject({ code: "unavailable" });
    serve(() => []);
    const error = await createHerdrDestination({ socketPath: socketPath(), timeoutMs: 100 })
      .deliver({ memoId: "m", transcript: "t", tab: "w2:t1" })
      .catch((e: unknown) => e);
    expect(error).toMatchObject({ code: "unavailable", message: "herdr: no answer within 100 ms" });
  });
});
