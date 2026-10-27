import { describe, expect, it } from "bun:test";
import { seedMemo, testStore } from "../memo/test-support.js";
import type { Memo, MemoState } from "../memo/memo.js";
import {
  buildAlert,
  buildLiveActivityEnd,
  buildLiveActivityUpdate,
  buildNeedsRouteAlert,
  MAX_PAYLOAD_BYTES,
  phaseOf,
  routeChip,
  truncate,
} from "./payloads.js";

const TOPIC = "com.example.iris";
const NOW = new Date("2026-01-01T12:00:00.000Z");
const NOW_SECONDS = 1767268800;

const summary = { headline: "Buy milk", detail: "Buy milk tomorrow", spoken: "Buy milk." };

function memoWith(patch: Partial<Memo> = {}): Memo {
  const { store } = testStore();
  return { ...seedMemo(store, "summarized"), ...patch };
}

const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;

describe("alert", () => {
  it("carries the route chip, the headline and the rich-notification keys", () => {
    const memo = memoWith({ route: "hermes" });
    expect(buildAlert({ topic: TOPIC, memo, summary })).toEqual({
      headers: { topic: TOPIC, pushType: "alert", priority: 10, collapseId: memo.id },
      payload: {
        aps: {
          alert: { title: "Hermes", body: "Buy milk" },
          "mutable-content": 1,
          category: "MEMO_DONE",
          "thread-id": "memo",
          sound: "default",
        },
        memo: memo.id,
      },
    });
  });

  it("collapses re-sends by memo id within the APNs 64-byte limit", () => {
    const memo = memoWith();
    const { headers } = buildAlert({ topic: TOPIC, memo, summary });
    expect(headers.collapseId).toBe(memo.id);
    expect(new TextEncoder().encode(headers.collapseId).length).toBeLessThanOrEqual(64);
  });

  it("falls back to Iris without a route and never leaks transcript, reply, detail or spoken text", () => {
    const memo = memoWith({
      route: null,
      transcript: "secret transcript",
      replyText: "secret reply",
    });
    const { payload } = buildAlert({ topic: TOPIC, memo, summary });
    const json = JSON.stringify(payload);
    expect((payload["aps"] as { alert: { title: string } }).alert.title).toBe("Iris");
    for (const secret of ["secret", "tomorrow", "Buy milk."]) expect(json).not.toContain(secret);
  });

  it("stays under 4 KB for hostile input", () => {
    const memo = memoWith({ route: "𝒳".repeat(500) });
    const huge = { headline: "\u0001𝒳".repeat(5000), detail: "d".repeat(9000), spoken: "s" };
    const { payload } = buildAlert({ topic: TOPIC, memo, summary: huge });
    expect(bytes(payload)).toBeLessThan(MAX_PAYLOAD_BYTES);
  });
});

describe("Live Activity update", () => {
  it("is priority 5 on the liveactivity topic with a bare processing state", () => {
    const memo = memoWith({ state: "received" as MemoState, summary: null, route: null });
    expect(buildLiveActivityUpdate({ topic: TOPIC, memo, now: NOW })).toEqual({
      headers: {
        topic: `${TOPIC}.push-type.liveactivity`,
        pushType: "liveactivity",
        priority: 5,
      },
      payload: {
        aps: {
          timestamp: NOW_SECONDS,
          event: "update",
          "content-state": { phase: "processing", hasReply: false },
        },
      },
    });
  });

  it("adds the route chip, the headline and hasReply once known, with no inputName", () => {
    const memo = memoWith({ route: "hermes", replyText: "ok", summary });
    const { payload } = buildLiveActivityUpdate({ topic: TOPIC, memo, now: NOW });
    expect((payload["aps"] as { "content-state": unknown })["content-state"]).toEqual({
      phase: "processing",
      routeChip: "Hermes",
      headline: "Buy milk",
      hasReply: true,
    });
  });

  it("caps the headline at 60 characters and stays under 4 KB", () => {
    const memo = memoWith({ summary: { ...summary, headline: "x".repeat(500) } });
    const { payload } = buildLiveActivityUpdate({ topic: TOPIC, memo, now: NOW });
    const state = (payload["aps"] as { "content-state": { headline: string } })["content-state"];
    expect(Array.from(state.headline)).toHaveLength(60);
    expect(bytes(payload)).toBeLessThan(MAX_PAYLOAD_BYTES);
  });

  it("maps every memo state to the client phase", () => {
    const phases: Record<MemoState, string> = {
      receiving: "processing",
      received: "processing",
      transcribed: "processing",
      routed: "processing",
      acted: "processing",
      summarized: "processing",
      needs_route: "needsRoute",
      notified: "done",
      failed: "failed",
    };
    for (const [state, phase] of Object.entries(phases)) {
      expect(phaseOf(state as MemoState)).toBe(phase as ReturnType<typeof phaseOf>);
    }
  });
});

describe("Live Activity end", () => {
  it("is priority 10, dismisses 15 minutes later and carries the final state", () => {
    const memo = memoWith({ route: "hermes", replyText: "ok" });
    expect(buildLiveActivityEnd({ topic: TOPIC, memo, summary, now: NOW })).toEqual({
      headers: {
        topic: `${TOPIC}.push-type.liveactivity`,
        pushType: "liveactivity",
        priority: 10,
      },
      payload: {
        aps: {
          timestamp: NOW_SECONDS,
          event: "end",
          "dismissal-date": NOW_SECONDS + 900,
          "content-state": {
            phase: "done",
            routeChip: "Hermes",
            headline: "Buy milk",
            hasReply: true,
          },
        },
      },
    });
  });

  it("stays under 4 KB", () => {
    const huge = { headline: "𝒳".repeat(5000), detail: "d", spoken: "s" };
    const { payload } = buildLiveActivityEnd({
      topic: TOPIC,
      memo: memoWith({ route: "r".repeat(500) }),
      summary: huge,
      now: NOW,
    });
    expect(bytes(payload)).toBeLessThan(MAX_PAYLOAD_BYTES);
  });
});

describe("helpers", () => {
  it("truncates by code point", () => {
    expect(truncate("abc", 3)).toBe("abc");
    expect(truncate("abcd", 3)).toBe("ab…");
    expect(truncate("𝒳𝒳𝒳", 2)).toBe("𝒳…");
  });

  it("capitalises the route and ignores an absent one", () => {
    expect(routeChip("hermes")).toBe("Hermes");
    expect(routeChip(null)).toBeNull();
    expect(routeChip("")).toBeNull();
  });
});

describe("needs-route alert", () => {
  it("is a priority-10 MEMO_NEEDS_ROUTE alert with the memo id, collapsing with the done alert", () => {
    const memo = memoWith({ state: "needs_route", route: null });
    const message = buildNeedsRouteAlert({ topic: TOPIC, memo, reason: "journal not available" });
    expect(message).toEqual({
      headers: { topic: TOPIC, pushType: "alert", priority: 10, collapseId: memo.id },
      payload: {
        aps: {
          alert: { title: "Where should this go?", body: "journal not available" },
          "mutable-content": 1,
          category: "MEMO_NEEDS_ROUTE",
          "thread-id": "memo",
          sound: "default",
        },
        memo: memo.id,
      },
    });
    expect(message.headers.collapseId).toBe(
      buildAlert({ topic: TOPIC, memo, summary }).headers.collapseId,
    );
  });

  it("falls back to a generic body, caps a long reason and never leaks transcript or reply", () => {
    const memo = memoWith({
      state: "needs_route",
      transcript: "secret transcript text",
      replyText: "secret reply text",
    });
    const bare = buildNeedsRouteAlert({ topic: TOPIC, memo, reason: null });
    const long = buildNeedsRouteAlert({ topic: TOPIC, memo, reason: "r".repeat(500) });
    expect((bare.payload["aps"] as { alert: { body: string } }).alert.body).toBe(
      "Choose a destination to continue.",
    );
    expect(
      Array.from((long.payload["aps"] as { alert: { body: string } }).alert.body),
    ).toHaveLength(200);
    for (const message of [bare, long]) {
      const text = JSON.stringify(message);
      expect(text).not.toContain("secret");
      expect(bytes(message.payload)).toBeLessThan(MAX_PAYLOAD_BYTES);
    }
  });
});
