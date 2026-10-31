import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TabGoneError } from "../ports/destination.js";
import {
  createHcDestination,
  createHcHerd,
  createHcTransport,
  HcError,
  type HcTransport,
} from "./hc.js";

type Call = { method: string; params: Record<string, unknown> | undefined };

/** An in-memory core: `terminal.list` filters by labels like the real one, `terminal.send` is recorded. */
function fakeCore(options: { terminals: unknown[]; send?: () => Promise<unknown> | unknown }) {
  const calls: Call[] = [];
  const transport: HcTransport = {
    async call({ method, params }) {
      calls.push({ method, params });
      if (method === "terminal.list") {
        const want = (params?.["labels"] ?? {}) as Record<string, string>;
        const terminals = (options.terminals as { labels?: Record<string, string> }[]).filter((t) =>
          Object.entries(want).every(([k, v]) => t.labels?.[k] === v),
        );
        return { terminals, hidden_finished: 0, machines: [] };
      }
      if (method === "terminal.send") return options.send ? options.send() : { turn: 1 };
      throw new Error(`unexpected ${method}`);
    },
  };
  return { transport, calls };
}

const term = (
  address: string,
  tab: string | undefined,
  where: string | undefined,
  status: string | null,
  extra: Record<string, unknown> = {},
) => ({
  address,
  cwd: "/Users/someone/SourceRoot/iris",
  state: "live",
  labels: {
    ...(tab !== undefined && { "herdr.tab": tab }),
    ...(where !== undefined && { where }),
  },
  status: status === null ? null : { app: "claude-code", state: status },
  ...extra,
});

const terminals = [
  term("t3", "tbA", "iris / server", "working"),
  term("t4", "tbB", "iris / 1", null),
  term("t5", undefined, undefined, "working"), // an unlabelled worker: no tab
  term("t6", "tbC", "── TOOLING ── / 1", null), // a sidebar divider
  term("mac/t1", "tbM", "iris / 9", "idle"), // a linked machine's terminal
  term("t7", "tbD", undefined, "weird", { cwd: "/Users/someone/IuRoot/api" }),
  term("t8", "tbE", "dotfiles / wave", "idle"),
  term("t9", "tbE", "dotfiles / wave", "blocked"),
];

describe("hc herd", () => {
  it("lists labelled tabs of this host, ids from herdr.tab, names from the where label", async () => {
    const { transport } = fakeCore({ terminals });
    const tabs = await createHcHerd({ transport }).snapshot();
    expect(tabs).toEqual([
      { id: "tbA", repo: "iris", label: "server", agentState: "working", lastActivity: null },
      { id: "tbB", repo: "iris", label: "1", agentState: "unknown", lastActivity: null },
      // no `where` label: the cwd names the repo; an unknown status word reads unknown
      { id: "tbD", repo: "api", label: "1", agentState: "unknown", lastActivity: null },
      // two programs in one tab: the most urgent state wins
      { id: "tbE", repo: "dotfiles", label: "wave", agentState: "blocked", lastActivity: null },
    ]);
  });

  it("is unavailable when the core answers an error or off-schema", async () => {
    const failing: HcTransport = {
      call: () =>
        Promise.reject(new HcError("terminal.list", "unavailable", "the core is stopping")),
    };
    await expect(createHcHerd({ transport: failing }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
    });
    const odd: HcTransport = { call: () => Promise.resolve({ nope: true }) };
    await expect(createHcHerd({ transport: odd }).snapshot()).rejects.toMatchObject({
      code: "unavailable",
    });
  });
});

const deliver = (transport: HcTransport, tab: string | undefined, transcript = "run the tests") =>
  createHcDestination({ transport }).deliver({
    memoId: "memo-1",
    transcript,
    ...(tab !== undefined && { tab }),
  });

describe("hc destination", () => {
  it("sends the transcript to the tab's one agent terminal", async () => {
    const { transport, calls } = fakeCore({ terminals });
    expect(await deliver(transport, "tbA", "run\nit")).toEqual({ ref: "tbA", replyText: "" });
    const list = { method: "terminal.list", params: { labels: { "herdr.tab": "tbA" } } };
    // the listing is repeated inside the terminal's queue turn, right before the send
    expect(calls).toEqual([
      list,
      list,
      { method: "terminal.send", params: { terminal: "t3", text: "run\nit" } },
    ]);
  });

  it("uses the only terminal of a tab with no reporting agent", async () => {
    const { transport, calls } = fakeCore({ terminals });
    await deliver(transport, "tbB");
    expect(calls[2]).toMatchObject({ params: { terminal: "t4" } });
  });

  it("prefers the one terminal that reports status over a plain shell", async () => {
    const { transport, calls } = fakeCore({
      terminals: [term("t1", "tbX", "x / 1", null), term("t2", "tbX", "x / 1", "idle")],
    });
    await deliver(transport, "tbX");
    expect(calls[2]).toMatchObject({ params: { terminal: "t2" } });
  });

  it("does not guess between several agents or several shells", async () => {
    const { transport, calls } = fakeCore({ terminals });
    await expect(deliver(transport, "tbE")).rejects.toMatchObject({ code: "unavailable" });
    expect(calls.map((c) => c.method)).toEqual(["terminal.list"]);
  });

  it("throws TabGoneError for a tab with no live terminal, sending nothing", async () => {
    const { transport, calls } = fakeCore({ terminals });
    const error = await deliver(transport, "tbNone").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(TabGoneError);
    expect(error).toMatchObject({ tab: "tbNone" });
    expect(calls.map((c) => c.method)).toEqual(["terminal.list"]);
  });

  it("ignores a linked machine's terminal carrying the tab label", async () => {
    const { transport } = fakeCore({ terminals });
    await expect(deliver(transport, "tbM")).rejects.toBeInstanceOf(TabGoneError);
  });

  it("is unavailable without a tab", async () => {
    const { transport, calls } = fakeCore({ terminals });
    await expect(deliver(transport, undefined)).rejects.toMatchObject({ code: "unavailable" });
    expect(calls).toEqual([]);
  });

  it("maps a terminal that ended between list and send to TabGoneError", async () => {
    for (const kind of ["not_found", "finished"]) {
      const { transport } = fakeCore({
        terminals,
        send: () => Promise.reject(new HcError("terminal.send", kind, kind)),
      });
      await expect(deliver(transport, "tbA")).rejects.toBeInstanceOf(TabGoneError);
    }
  });

  it("is unavailable, naming the reason, for a blocked agent", async () => {
    const { transport } = fakeCore({
      terminals,
      send: () => Promise.reject(new HcError("terminal.send", "blocked", "blocked")),
    });
    await expect(deliver(transport, "tbA")).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("blocked"),
    });
  });

  it("does not send when the terminal left the tab while waiting in line", async () => {
    let listings = 0;
    const transport: HcTransport = {
      async call({ method }) {
        if (method === "terminal.send") throw new Error("must not send");
        listings++;
        // the first listing finds t3 in tbA, the second (inside the queue turn) no longer does
        return {
          terminals: listings === 1 ? [terminals[0]] : [],
          hidden_finished: 0,
          machines: [],
        };
      },
    };
    await expect(deliver(transport, "tbA")).rejects.toBeInstanceOf(TabGoneError);
  });

  it("is unavailable, not delivered, when the send answer is off-schema", async () => {
    const { transport } = fakeCore({ terminals, send: () => ({ nope: true }) });
    await expect(deliver(transport, "tbA")).rejects.toMatchObject({ code: "unavailable" });
  });

  it("turns a core error on the listing into unavailable (never an HcError)", async () => {
    const transport: HcTransport = {
      call: () =>
        Promise.reject(new HcError("terminal.list", "unavailable", "the core is stopping")),
    };
    await expect(deliver(transport, "tbA")).rejects.toMatchObject({ code: "unavailable" });
  });

  it("serialises deliveries to one terminal and fails the one past the line", async () => {
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    const order: string[] = [];
    const { transport } = fakeCore({
      terminals,
      send: async () => {
        order.push("send");
        await gate;
        order.push("sent");
        return { turn: 1 };
      },
    });
    const destination = createHcDestination({ transport, maxTerminalQueue: 2 });
    const params = (n: number) => ({ memoId: `m${n}`, transcript: `t${n}`, tab: "tbA" });
    const first = destination.deliver(params(1));
    const second = destination.deliver(params(2));
    await Bun.sleep(20);
    expect(order).toEqual(["send"]); // the second waits behind the first
    await expect(destination.deliver(params(3))).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("queue is full"),
    });
    release();
    await Promise.all([first, second]);
    expect(order).toEqual(["send", "sent", "send", "sent"]);
  });
});

// The real transport against a stub `hc` executable: JSON-RPC lines on stdin/stdout.

describe("hc transport", () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "iris-hc-"));
  });
  afterEach(() => rm(dir, { recursive: true, force: true }));

  /** A stub `hc connect`: `body` is the JS that answers (`request`, the parsed line, is in scope). */
  async function stub(body: string): Promise<string> {
    const bin = join(dir, "hc");
    await writeFile(
      bin,
      `#!${process.execPath}
if (process.argv[2] !== "connect") process.exit(2);
const decoder = new TextDecoder();
let buf = "";
for await (const chunk of Bun.stdin.stream()) {
  buf += decoder.decode(chunk);
  const end = buf.indexOf("\\n");
  if (end < 0) continue;
  const request = JSON.parse(buf.slice(0, end));
  buf = buf.slice(end + 1);
  ${body}
}
`,
    );
    await chmod(bin, 0o755);
    return bin;
  }

  /** The stub's "core socket": a listening unix socket, which is all the transport's probe asks of a core. */
  const sock = () => join(dir, "default.sock");
  let core: ReturnType<typeof Bun.listen> | undefined;
  beforeEach(() => {
    core = Bun.listen({ unix: sock(), socket: { data() {} } });
  });
  afterEach(() => core?.stop(true));

  const list = (transport: HcTransport, timeoutMs = 5000) =>
    transport.call({ method: "terminal.list", params: { labels: { a: "b" } }, timeoutMs });

  it("sends one request line and resolves with the matching result, skipping other lines", async () => {
    const bin = await stub(`
      console.log(JSON.stringify({ jsonrpc: "2.0", method: "heartbeat", params: { seq: 1 } }));
      console.log(JSON.stringify({ jsonrpc: "2.0", id: 999, result: "other" }));
      console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { echo: request } }));
    `);
    const result = (await list(createHcTransport({ bin, socket: sock() }))) as {
      echo: Record<string, unknown>;
    };
    expect(result.echo).toMatchObject({
      jsonrpc: "2.0",
      method: "terminal.list",
      params: { labels: { a: "b" } },
    });
  });

  it("is unavailable when the answer carries neither result nor error", async () => {
    const bin = await stub(`console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id }));`);
    await expect(list(createHcTransport({ bin, socket: sock() }))).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("without a result"),
    });
  });

  it("gives the child nothing but HC_SOCKET", async () => {
    const bin = await stub(`
      console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { env: process.env } }));
    `);
    process.env["IRIS_TEST_SECRET"] = "s3cret";
    try {
      const { env } = (await list(createHcTransport({ bin, socket: sock() }))) as {
        env: Record<string, string>;
      };
      expect(env["HC_SOCKET"]).toBe(sock());
      expect(Object.keys(env)).not.toContain("IRIS_TEST_SECRET");
    } finally {
      delete process.env["IRIS_TEST_SECRET"];
    }
  });

  it("throws an HcError with the core's kind on an error answer", async () => {
    const bin = await stub(`
      console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: -32000, message: "blocked", data: { kind: "blocked" } } }));
    `);
    await expect(list(createHcTransport({ bin, socket: sock() }))).rejects.toMatchObject({
      name: "HcError",
      kind: "blocked",
    });
  });

  it("is unavailable when the binary is missing, exits without an answer, or stays silent", async () => {
    await expect(
      list(createHcTransport({ bin: join(dir, "absent"), socket: sock() })),
    ).rejects.toMatchObject({
      code: "unavailable",
    });
    const quits = await stub("process.exit(1);");
    await expect(list(createHcTransport({ bin: quits, socket: sock() }))).rejects.toMatchObject({
      code: "unavailable",
    });
    const silent = await stub("await Bun.sleep(10_000);");
    const started = Date.now();
    await expect(
      list(createHcTransport({ bin: silent, socket: sock() }), 300),
    ).rejects.toMatchObject({
      code: "unavailable",
      message: expect.stringContaining("no answer within 300 ms"),
    });
    expect(Date.now() - started).toBeLessThan(3000);
  });

  it("refuses without spawning while the core's socket is missing or left over by a dead core", async () => {
    const marker = join(dir, "spawned");
    const bin = await stub(`await Bun.write(${JSON.stringify(marker)}, "x");`);
    const leftover = join(dir, "leftover.sock");
    await writeFile(leftover, "");
    for (const socket of [join(dir, "missing.sock"), leftover]) {
      await expect(list(createHcTransport({ bin, socket }))).rejects.toMatchObject({
        code: "unavailable",
        message: expect.stringContaining("no core is running"),
      });
    }
    expect(await Bun.file(marker).exists()).toBe(false);
  });
});
