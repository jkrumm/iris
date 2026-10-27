import { describe, expect, it } from "bun:test";
import { CHAT_SYSTEM_MESSAGE, createHermesDestination } from "./hermes.js";

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
  d.deliver({ memoId: MEMO_ID, transcript: "buy milk" });

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
      usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
    });

    expect(calls).toHaveLength(2);
    const [create, chat] = calls;
    // The session URL drops the /v1 path of the base URL, like Hermes' /api routes require.
    expect(create?.url).toBe("http://127.0.0.1:1234/api/sessions");
    expect(JSON.parse(String(create?.init.body))).toEqual({ id: MEMO_ID, source: "iris" });
    expect(chat?.url).toBe(`http://127.0.0.1:1234/api/sessions/${MEMO_ID}/chat/stream`);
    expect(JSON.parse(String(chat?.init.body))).toEqual({ message: "buy milk" });
    for (const call of calls) {
      expect((call.init.headers as Record<string, string>)["Authorization"]).toBe(
        "Bearer test-token",
      );
    }
  });

  it("opens a chat session with source iris-chat and sends the no-side-effects system message", async () => {
    const { calls, destination } = fakeHermes({
      chat: () => sseResponse([completed("a monad is..."), done]),
    });
    const delivery = await destination.deliver({
      memoId: MEMO_ID,
      transcript: "what is a monad?",
      chat: true,
    });
    expect(delivery.ref).toBe(MEMO_ID);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({
      id: MEMO_ID,
      source: "iris-chat",
    });
    expect(JSON.parse(String(calls[1]?.init.body))).toEqual({
      message: "what is a monad?",
      system_message: CHAT_SYSTEM_MESSAGE,
    });
    expect(CHAT_SYSTEM_MESSAGE).toContain("NO actions with side effects");
  });

  it("names the thread: the session id, its kind and a title from the transcript", async () => {
    const { destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    const long = `${"word ".repeat(30)}end`;
    const chat = await destination.deliver({ memoId: MEMO_ID, transcript: long, chat: true });
    expect(chat.thread).toEqual({
      id: MEMO_ID,
      kind: "chat",
      title: `${"word ".repeat(11)}word…`,
    });
    const plain = await destination.deliver({ memoId: MEMO_ID, transcript: " a\n b " });
    expect(plain.thread).toEqual({ id: MEMO_ID, kind: "hermes", title: "a b" });
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

describe("hermes destination, continuing a thread", () => {
  const THREAD = "b6d2e8a4-3f91-4c07-9a52-7e1d0c4f8b63";

  it("chats into the thread's session without creating one", async () => {
    const { calls, destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    const delivery = await destination.deliver({
      memoId: MEMO_ID,
      transcript: "and then?",
      threadId: THREAD,
    });
    expect(calls.map((c) => c.url)).toEqual([
      `http://127.0.0.1:1234/api/sessions/${THREAD}/chat/stream`,
    ]);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ message: "and then?" });
    expect(delivery).toMatchObject({ ref: THREAD, thread: { id: THREAD, kind: "hermes" } });
  });

  it("sends the no-side-effects instruction again on every turn of a chat thread", async () => {
    const { calls, destination } = fakeHermes({ chat: () => sseResponse([completed("ok"), done]) });
    const delivery = await destination.deliver({
      memoId: MEMO_ID,
      transcript: "and then?",
      chat: true,
      threadId: THREAD,
    });
    expect(calls).toHaveLength(1);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({
      message: "and then?",
      system_message: CHAT_SYSTEM_MESSAGE,
    });
    expect(delivery.thread?.kind).toBe("chat");
  });
});
