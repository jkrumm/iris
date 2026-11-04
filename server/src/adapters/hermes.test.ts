import { describe, expect, it } from "bun:test";
import { captureLogs } from "../memo/test-support.js";
import type { MemoMode } from "../memo/memo.js";
import { transientKind } from "../ports/transient.js";
import {
  createHermesDestination,
  IRIS_SYSTEM_MESSAGE,
  actionOf,
  parseIrisBlock,
  systemMessage,
} from "./hermes.js";

const MEMO_ID = "0f8fad5b-d9cb-469f-a165-70867728950e";
const BASE_URL = "http://127.0.0.1:1234/v1";

const env = { session_id: MEMO_ID, run_id: "r1", seq: 1, ts: 1 };

function frame(event: string, data: Record<string, unknown>): string {
  return `event: ${event}\ndata: ${JSON.stringify({ ...env, ...data })}\n\n`;
}

const completed = (content: string, extra: Record<string, unknown> = {}) =>
  frame("assistant.completed", {
    message_id: "m1",
    content,
    partial: false,
    interrupted: false,
    ...extra,
  });
const runCompleted = frame("run.completed", {
  message_id: "m1",
  usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
});
const done = frame("done", {});
const toolStarted = (data: Record<string, unknown>) => frame("tool.started", data);
const irisBlock = (json: string) => `\n\n\`\`\`iris\n${json}\n\`\`\``;

function sseResponse(chunks: string[], status = 200): Response {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
  return new Response(body, { status, headers: { "content-type": "text/event-stream" } });
}

interface Call {
  url: string;
  init: RequestInit;
}

function fakeHermes(opts: {
  sessionStatus?: number;
  idleMs?: number;
  chat: (init: RequestInit) => Response | Promise<Response>;
}) {
  const calls: Call[] = [];
  const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init: init ?? {} });
    if (url.endsWith("/api/sessions")) {
      return opts.sessionStatus === 409
        ? Response.json({ error: { message: "exists", code: "session_exists" } }, { status: 409 })
        : Response.json({ id: MEMO_ID }, { status: opts.sessionStatus ?? 201 });
    }
    return opts.chat(init ?? {});
  }) as typeof fetch;
  const destination = createHermesDestination({
    baseUrl: BASE_URL,
    token: "test-token",
    fetch: fakeFetch,
    ...(opts.idleMs !== undefined ? { idleMs: opts.idleMs } : {}),
  });
  return { calls, destination };
}

const deliver = (d: ReturnType<typeof fakeHermes>["destination"]) =>
  d.deliver({ memoId: MEMO_ID, transcript: "buy milk", mode: "auto" });

describe("hermes destination", () => {
  it("creates the session, streams the chat and returns the final reply with usage", async () => {
    const { calls, destination } = fakeHermes({
      chat: () =>
        sseResponse([
          ": keepalive\n\n",
          frame("run.started", {}),
          frame("assistant.delta", { message_id: "m1", delta: "Do" }),
          frame("assistant.completed", {
            message_id: "m0",
            content: "interim",
            partial: true,
            interrupted: false,
          }),
          completed("Done, milk is on the list."),
          runCompleted,
          done,
        ]),
    });
    const delivery = await deliver(destination);
    expect(delivery).toEqual({
      ref: MEMO_ID,
      replyText: "Done, milk is on the list.",
      thread: { id: MEMO_ID, kind: "hermes", title: "buy milk" },
      meta: { kind: null, summary: null, actions: [] },
      usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
    });

    expect(calls).toHaveLength(2);
    const [create, chat] = calls;
    // The session URL drops the /v1 path of the base URL, like Hermes' /api routes require.
    expect(create?.url).toBe("http://127.0.0.1:1234/api/sessions");
    expect(JSON.parse(String(create?.init.body))).toEqual({ id: MEMO_ID, source: "iris" });
    expect(chat?.url).toBe(`http://127.0.0.1:1234/api/sessions/${MEMO_ID}/chat/stream`);
    expect(JSON.parse(String(chat?.init.body))).toEqual({
      message: "buy milk",
      system_message: IRIS_SYSTEM_MESSAGE,
    });
    for (const call of calls) {
      expect((call.init.headers as Record<string, string>)["Authorization"]).toBe(
        "Bearer test-token",
      );
    }
  });

  it("sends the system message for the mode the owner picked, on a new session", async () => {
    const sent: Record<MemoMode, string> = {} as Record<MemoMode, string>;
    for (const mode of ["auto", "hermes", "chat", "journal", "tab"] as const) {
      const { calls, destination } = fakeHermes({
        chat: () => sseResponse([completed("ok"), done]),
      });
      await destination.deliver({ memoId: MEMO_ID, transcript: "x", mode });
      expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ id: MEMO_ID, source: "iris" });
      sent[mode] = JSON.parse(String(calls[1]?.init.body)).system_message;
    }
    expect(sent.auto).toBe(IRIS_SYSTEM_MESSAGE);
    expect(sent.hermes).toBe(IRIS_SYSTEM_MESSAGE);
    expect(sent.chat).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Chat.`);
    expect(sent.journal).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Journal.`);
    expect(sent.tab).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Tab.`);
  });

  it("names the thread: the session id, kind hermes and a title from the transcript", async () => {
    const { destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    const long = `${"word ".repeat(30)}end`;
    const first = await destination.deliver({ memoId: MEMO_ID, transcript: long, mode: "chat" });
    expect(first.thread).toEqual({
      id: MEMO_ID,
      kind: "hermes",
      title: `${"word ".repeat(11)}word…`,
    });
    const plain = await deliver(destination);
    expect(plain.thread).toEqual({ id: MEMO_ID, kind: "hermes", title: "buy milk" });
  });

  it("reassembles frames split across chunks and omits usage when run.completed has none", async () => {
    const whole = completed("split reply") + frame("run.completed", { message_id: "m1" }) + done;
    const cut = [7, 40, whole.length - 5];
    const chunks = [
      whole.slice(0, cut[0]),
      whole.slice(cut[0], cut[1]),
      whole.slice(cut[1], cut[2]),
      whole.slice(cut[2]),
    ];
    const { destination } = fakeHermes({ chat: () => sseResponse(chunks) });
    const delivery = await deliver(destination);
    expect(delivery).toMatchObject({ ref: MEMO_ID, replyText: "split reply" });
    expect("usage" in delivery).toBe(false);
  });

  it("treats 409 session_exists as success", async () => {
    const { calls, destination } = fakeHermes({
      sessionStatus: 409,
      chat: () => sseResponse([completed("ok"), done]),
    });
    expect((await deliver(destination)).replyText).toBe("ok");
    expect(calls).toHaveLength(2);
  });

  it("fails the session create on other statuses with the envelope message", async () => {
    const calls: string[] = [];
    const destination = createHermesDestination({
      baseUrl: BASE_URL,
      token: "t",
      fetch: (async (input: string | URL | Request) => {
        calls.push(String(input));
        return Response.json(
          { error: { message: "bad key", code: "unauthorized" } },
          { status: 401 },
        );
      }) as typeof fetch,
    });
    await expect(deliver(destination)).rejects.toThrow("hermes session create failed: 401 bad key");
    expect(calls).toHaveLength(1);
  });

  it("surfaces a pre-stream error envelope", async () => {
    const { destination } = fakeHermes({
      chat: () =>
        Response.json(
          { error: { message: "session_not_found", type: "x", param: null, code: "nf" } },
          { status: 404 },
        ),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes chat failed: 404 session_not_found");
  });

  it("falls back to a truncated raw body when the pre-stream error is not an envelope", async () => {
    const { destination } = fakeHermes({
      chat: () => new Response("x".repeat(1000), { status: 502 }),
    });
    const error = await deliver(destination).catch((e: Error) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toBe(`hermes chat failed: 502 ${"x".repeat(300)}`);
  });

  it("throws the message of an error event", async () => {
    const { destination } = fakeHermes({
      chat: () => sseResponse([frame("error", { message: "model overloaded" }), done]),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes error: model overloaded");
  });

  it("throws when the stream ends without done", async () => {
    const { destination } = fakeHermes({
      chat: () => sseResponse([completed("partial answer"), runCompleted]),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes stream ended without done");
  });

  it("throws when the final reply was interrupted", async () => {
    const { destination } = fakeHermes({
      chat: () => sseResponse([completed("cut off", { interrupted: true }), runCompleted, done]),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes reply was interrupted");
  });

  it("uses the last non-partial reply when several complete", async () => {
    const { destination } = fakeHermes({
      chat: () => sseResponse([completed("first"), completed("second"), done]),
    });
    expect((await deliver(destination)).replyText).toBe("second");
  });

  it("aborts a stream that goes silent for idleMs", async () => {
    const encoder = new TextEncoder();
    const { destination } = fakeHermes({
      idleMs: 30,
      chat: () =>
        new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(encoder.encode(frame("run.started", {})));
              // never closes: Hermes went quiet mid-turn
            },
          }),
        ),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes stream idle for 30 ms");
  });

  it("keeps a slow stream alive while keepalive bytes keep arriving", async () => {
    const encoder = new TextEncoder();
    const parts = [
      ": keepalive\n\n",
      ": keepalive\n\n",
      ": keepalive\n\n",
      completed("late"),
      done,
    ];
    const { destination } = fakeHermes({
      idleMs: 60,
      chat: () =>
        new Response(
          new ReadableStream<Uint8Array>({
            async pull(controller) {
              const part = parts.shift();
              if (part === undefined) return controller.close();
              await Bun.sleep(25);
              controller.enqueue(encoder.encode(part));
            },
          }),
        ),
    });
    expect((await deliver(destination)).replyText).toBe("late");
  });

  it("gives up when Hermes never answers the chat request", async () => {
    const { destination } = fakeHermes({
      idleMs: 30,
      chat: (init) =>
        new Promise<Response>((_, reject) => {
          init.signal?.addEventListener("abort", () => reject(new Error("aborted")));
        }),
    });
    await expect(deliver(destination)).rejects.toThrow("hermes did not respond within 30 ms");
  });
});

const kindOf = async (chat: (init: RequestInit) => Response | Promise<Response>) => {
  const { destination } = fakeHermes({ chat, idleMs: 30 });
  return transientKind(await deliver(destination).catch((e: unknown) => e));
};

describe("hermes destination, transient failures", () => {
  it("marks a refused connection before_send", async () => {
    const refused = Object.assign(new TypeError("fetch failed"), {
      cause: Object.assign(new Error("connect"), { code: "ECONNREFUSED" }),
    });
    expect(await kindOf(() => Promise.reject(refused))).toBe("before_send");
  });

  it("marks a 5xx after_send", async () => {
    expect(await kindOf(() => new Response("down", { status: 503 }))).toBe("after_send");
  });

  it("fails a hung call for good: no response within the idle window, or a stream gone idle", async () => {
    const silent = (init: RequestInit) =>
      new Promise<Response>((_, reject) => {
        init.signal?.addEventListener("abort", () => reject(new Error("aborted")));
      });
    expect(await kindOf(silent)).toBeNull();

    const stalled = (init: RequestInit) => {
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(completed("partial")));
          init.signal?.addEventListener("abort", () => controller.error(new Error("aborted")));
        },
      });
      return new Response(body, { status: 200 });
    };
    expect(await kindOf(stalled)).toBeNull();
  });

  it("leaves a 4xx and an error event final", async () => {
    expect(await kindOf(() => new Response("nope", { status: 404 }))).toBeNull();
    expect(
      await kindOf(() => sseResponse([frame("error", { message: "overloaded" }), done])),
    ).toBeNull();
  });
});

describe("hermes destination, continuing a thread", () => {
  const THREAD = "b6d2e8a4-3f91-4c07-9a52-7e1d0c4f8b63";

  it("chats into the thread's session without creating one, sending the system message again", async () => {
    const { calls, destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    const delivery = await destination.deliver({
      memoId: MEMO_ID,
      transcript: "and then?",
      mode: "auto",
      threadId: THREAD,
    });
    expect(calls.map((c) => c.url)).toEqual([
      `http://127.0.0.1:1234/api/sessions/${THREAD}/chat/stream`,
    ]);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({
      message: "and then?",
      system_message: IRIS_SYSTEM_MESSAGE,
    });
    expect(delivery).toMatchObject({ ref: THREAD, thread: { id: THREAD, kind: "hermes" } });
  });

  it("adds the picked-mode line on a continuation too", async () => {
    const { calls, destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    await destination.deliver({
      memoId: MEMO_ID,
      transcript: "and then?",
      mode: "chat",
      threadId: THREAD,
    });
    expect(calls).toHaveLength(1);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({
      message: "and then?",
      system_message: systemMessage("chat"),
    });
  });
});

describe("systemMessage", () => {
  it("is the Iris message, plus the owner's pick for chat, journal and tab only", () => {
    expect(IRIS_SYSTEM_MESSAGE).toContain("```iris");
    expect(systemMessage("auto")).toBe(IRIS_SYSTEM_MESSAGE);
    expect(systemMessage("hermes")).toBe(IRIS_SYSTEM_MESSAGE);
    expect(systemMessage("transcribe")).toBe(IRIS_SYSTEM_MESSAGE);
    expect(systemMessage("chat")).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Chat.`);
    expect(systemMessage("journal")).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Journal.`);
    expect(systemMessage("tab")).toBe(`${IRIS_SYSTEM_MESSAGE}\nThe owner picked: Tab.`);
  });
});

const FENCE = (json: string) => "```iris\n" + json + "\n```";
const valid = JSON.stringify({
  kind: "Task",
  headline: "Buy milk",
  spoken: "Milk is on the list.",
});

describe("parseIrisBlock", () => {
  it("finds a block written on one line, and not a tag that merely starts with iris", () => {
    const json = '{"kind":"task","headline":"x","spoken":"y"}';
    const one = parseIrisBlock(`Done. \`\`\`iris ${json}\`\`\``);
    expect(one.meta?.kind).toBe("task");
    expect(one.reply).toBe("Done.");
    expect(parseIrisBlock(`Done.\n\`\`\`irisfoo\n${json}\n\`\`\``).invalid).toBe("missing_block");
  });

  it("reads a valid block and cuts the fence and the whitespace before it from the reply", () => {
    expect(parseIrisBlock(`Done.\n\n${FENCE(valid)}`)).toEqual({
      reply: "Done.",
      meta: {
        kind: "task",
        summary: { headline: "Buy milk", detail: "", spoken: "Milk is on the list." },
      },
    });
  });

  it("takes the last of two fences and cuts only that one", () => {
    const first = JSON.stringify({ kind: "a", headline: "First", spoken: "1" });
    const result = parseIrisBlock(`x\n${FENCE(first)}\nmid\n${FENCE(valid)}`);
    expect(result.meta?.kind).toBe("task");
    expect(result.meta?.summary?.headline).toBe("Buy milk");
    expect(result.reply).toBe(`x\n${FENCE(first)}\nmid`);
  });

  it("ignores extra keys and keeps the text after the fence", () => {
    const json = JSON.stringify({ kind: "note", headline: "H", spoken: "S", extra: 1 });
    const result = parseIrisBlock(`before\n${FENCE(json)}\nafter`);
    expect(result.meta).toEqual({
      kind: "note",
      summary: { headline: "H", detail: "", spoken: "S" },
    });
    expect(result.reply).toBe("before\nafter");
  });

  it("clips the headline to 60 code points and normalises the kind", () => {
    const json = JSON.stringify({
      kind: "  Task Item  ",
      headline: `  ${"ä".repeat(80)}  `,
      spoken: "S",
    });
    const { meta } = parseIrisBlock(FENCE(json));
    expect(meta?.kind).toBe("task item");
    expect([...(meta?.summary?.headline ?? "")]).toHaveLength(60);
    expect(meta?.summary?.headline.endsWith("…")).toBe(true);
    const long = parseIrisBlock(
      FENCE(JSON.stringify({ kind: "k".repeat(40), headline: "H", spoken: "" })),
    );
    expect([...(long.meta?.kind ?? "")]).toHaveLength(24);
  });

  it("leaves the summary out for a blank headline and the kind null for a blank kind", () => {
    expect(
      parseIrisBlock(FENCE(JSON.stringify({ kind: "note", headline: "   ", spoken: "S" }))).meta,
    ).toEqual({ kind: "note", summary: null });
    expect(
      parseIrisBlock(FENCE(JSON.stringify({ kind: " ", headline: "H", spoken: "S" }))).meta?.kind,
    ).toBeNull();
  });

  it("returns no meta and the reply as is without a fence", () => {
    expect(parseIrisBlock("just text\n")).toEqual({
      reply: "just text\n",
      meta: null,
      invalid: "missing_block",
    });
  });

  it("strips an invalid block anyway and says why", () => {
    expect(parseIrisBlock(`Hi\n${FENCE("{nope")}`)).toEqual({
      reply: "Hi",
      meta: null,
      invalid: "invalid_json",
    });
    expect(parseIrisBlock(`Hi\n${FENCE(JSON.stringify({ kind: "k", headline: "h" }))}`)).toEqual({
      reply: "Hi",
      meta: null,
      invalid: "invalid_shape: spoken",
    });
  });
});

describe("hermes destination, the iris block and tools", () => {
  const run = async (chunks: string[]) => {
    const { destination } = fakeHermes({ chat: () => sseResponse(chunks) });
    return deliver(destination);
  };

  it("returns the parsed meta and the reply without the block", async () => {
    const delivery = await run([completed(`Added.${irisBlock(valid)}`), runCompleted, done]);
    expect(delivery.replyText).toBe("Added.");
    expect(delivery.meta).toEqual({
      kind: "task",
      summary: { headline: "Buy milk", detail: "", spoken: "Milk is on the list." },
      actions: [],
    });
  });

  it("collects tool names from tool.started frames: deduplicated, first-seen order, names only", async () => {
    const delivery = await run([
      toolStarted({ tool_name: "web_search", args: { q: "secret query" } }),
      toolStarted({ tool_name: "write_file", preview: "secret" }),
      toolStarted({ tool_name: "web_search" }),
      completed("ok"),
      done,
    ]);
    expect(delivery.meta?.actions).toEqual(["web_search", "write_file"]);
    expect(JSON.stringify(delivery.meta)).not.toContain("secret");
  });

  it("records the loaded skill for skill_view, drops the iris skill and a skill_view without a usable name", async () => {
    const delivery = await run([
      toolStarted({ tool_name: "skill_view", args: { name: "iris" } }),
      toolStarted({ tool_name: "web_search" }),
      toolStarted({ tool_name: "skill_view", args: { name: "capture", file_path: "secret.md" } }),
      toolStarted({ tool_name: "skill_view" }),
      toolStarted({ tool_name: "skill_view", args: { name: 7 } }),
      toolStarted({ tool_name: "skill_view", args: "capture" }),
      toolStarted({ tool_name: "skill_view", args: { name: "  " } }),
      toolStarted({ tool_name: "skill_view", args: { name: "plugin:herdr" } }),
      toolStarted({ tool_name: "skill_view", args: { name: "capture" } }),
      toolStarted({ tool_name: "skill_view", args: { name: "productivity/obsidian" } }),
      toolStarted({ tool_name: "web_search" }),
      completed("ok"),
      done,
    ]);
    expect(delivery.meta?.actions).toEqual(["web_search", "capture", "herdr", "obsidian"]);
    expect(JSON.stringify(delivery.meta)).not.toContain("secret");
  });

  it("actionOf cuts a plugin prefix and a path to the last segment, and drops iris however it is spelled", () => {
    expect(actionOf({ tool_name: "terminal", args: { name: "iris" } })).toBe("terminal");
    expect(actionOf({ tool_name: "skill_view", args: { name: "plugin:03-x/axolotl" } })).toBe(
      "axolotl",
    );
    expect(actionOf({ tool_name: "skill_view", args: { name: "my-plugin:iris" } })).toBeNull();
    expect(actionOf({ tool_name: "skill_view", args: { name: "tools/iris" } })).toBeNull();
    expect(actionOf({ tool_name: "skill_view", args: null })).toBeNull();
  });

  it("keeps at most 12 actions", async () => {
    const frames = Array.from({ length: 20 }, (_, i) => toolStarted({ tool_name: `tool_${i}` }));
    const delivery = await run([...frames, completed("ok"), done]);
    expect(delivery.meta?.actions).toEqual(Array.from({ length: 12 }, (_, i) => `tool_${i}`));
  });

  it("ignores a tool frame without a tool name", async () => {
    const delivery = await run([
      toolStarted({ tool_name: 7 }),
      toolStarted({ name: "x" }),
      toolStarted({ tool_name: "ok_tool" }),
      completed("ok"),
      done,
    ]);
    expect(delivery.meta?.actions).toEqual(["ok_tool"]);
  });

  it("logs hermes.meta_invalid with a reason and never the reply", async () => {
    const secret = "very secret reply";
    const cases: [string, string][] = [
      [`${secret}`, "missing_block"],
      [`${secret}${irisBlock("{broken")}`, "invalid_json"],
      [
        `${secret}${irisBlock(JSON.stringify({ kind: "k", spoken: "s" }))}`,
        "invalid_shape: headline",
      ],
    ];
    for (const [content, reason] of cases) {
      const { result, lines } = await captureLogs(() => run([completed(content), done]));
      expect(result.meta).toEqual({ kind: null, summary: null, actions: [] });
      const invalid = lines.filter((l) => l["event"] === "hermes.meta_invalid");
      expect(invalid).toHaveLength(1);
      expect(invalid[0]).toMatchObject({ memo_id: MEMO_ID, reason });
      expect(JSON.stringify(lines)).not.toContain(secret);
    }
  });

  it("does not log meta_invalid for a valid block", async () => {
    const { lines } = await captureLogs(() => run([completed(`ok${irisBlock(valid)}`), done]));
    expect(lines.some((l) => l["event"] === "hermes.meta_invalid")).toBe(false);
  });
});
