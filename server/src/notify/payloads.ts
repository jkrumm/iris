import { t } from "elysia";
import { HEADLINE_MAX, type Memo, type MemoState, type Summary } from "../memo/memo.js";
import type { ApnsMessage } from "../ports/apns.js";

// Pure payload builders: no clock, no network. The headline comes from the summary Hermes reported; without one, `notify` passes a
// transcript-derived one (pipeline/steps.ts), clipped to HEADLINE_MAX. Apple limits both an alert and a Live Activity
// push to 4 KB; every free-text field is capped far below that. The two TypeBox schemas below are
// the push shapes the Swift clients decode; `contracts/` exports them.

export const MAX_PAYLOAD_BYTES = 4096;
/** How long an ended Live Activity stays on the Lock Screen. */
export const DISMISS_AFTER_MS = 15 * 60 * 1000;

const ALERT_BODY_MAX = 200;
const ROUTE_CHIP_MAX = 30;

export const LIVE_ACTIVITY_PHASES = ["processing", "done", "failed"] as const;
export type LiveActivityPhase = (typeof LIVE_ACTIVITY_PHASES)[number];

/**
 * The client's `MemoAttributes.ContentState` as plain camelCase JSON (Apple: no custom encoding
 * strategies). `inputName` is deliberately absent: the device knows it and the Swift side declares it optional.
 */
export const ContentState = t.Object({
  phase: t.UnionEnum([...LIVE_ACTIVITY_PHASES]),
  routeChip: t.Optional(t.String()),
  headline: t.Optional(t.String()),
  hasReply: t.Boolean(),
});
export type LiveActivityContentState = typeof ContentState.static;

/**
 * The whole alert body: Apple's `aps` dict plus the custom `memo` key (the memo id) the app routes on.
 * `MEMO_DONE` announces a finished memo.
 */
export const AlertPayload = t.Object({
  aps: t.Object({
    alert: t.Object({ title: t.String(), body: t.String() }),
    "mutable-content": t.Literal(1),
    category: t.Literal("MEMO_DONE"),
    "thread-id": t.Literal("memo"),
    sound: t.Literal("default"),
  }),
  memo: t.String(),
});
export type AlertPayloadBody = typeof AlertPayload.static;

/** Cuts to `max` code points with an ellipsis, never splitting a surrogate pair. */
export function truncate(text: string, max: number): string {
  const points = Array.from(text);
  if (points.length <= max) return text;
  return `${points.slice(0, max - 1).join("")}…`;
}

/** `note` → `Note`: the chip and alert title for a memo's kind; null when Hermes reported none. */
export function kindChip(kind: string | null): string | null {
  if (!kind) return null;
  return truncate(kind.charAt(0).toUpperCase() + kind.slice(1), ROUTE_CHIP_MAX);
}

export function phaseOf(state: MemoState): LiveActivityPhase {
  switch (state) {
    case "notified":
      return "done";
    case "failed":
      return "failed";
    default:
      return "processing";
  }
}

function contentState(params: {
  memo: Memo;
  phase: LiveActivityPhase;
  headline: string | null;
}): LiveActivityContentState {
  const { memo, phase, headline } = params;
  const chip = kindChip(memo.kind);
  return {
    phase,
    ...(chip !== null && { routeChip: chip }),
    ...(headline !== null && { headline: truncate(headline, HEADLINE_MAX) }),
    hasReply: memo.replyText !== null && memo.replyText !== "",
  };
}

const epochSeconds = (at: Date) => Math.floor(at.getTime() / 1000);

/** Priority 5 does not count toward the hourly Live Activity budget. */
export function buildLiveActivityUpdate(params: {
  topic: string;
  memo: Memo;
  now: Date;
}): ApnsMessage {
  const { topic, memo, now } = params;
  return {
    headers: { topic: `${topic}.push-type.liveactivity`, pushType: "liveactivity", priority: 5 },
    payload: {
      aps: {
        timestamp: epochSeconds(now),
        event: "update",
        "content-state": contentState({
          memo,
          phase: phaseOf(memo.state),
          headline: memo.summary?.headline ?? null,
        }),
      },
    },
  };
}

/**
 * The announcement of a finished take: a final `update` (phase fixed to done, the memo is still `acted` when notify runs) that carries
 * the `alert` (kind chip or "Iris", the headline, the default sound). Apple documents the alert sound for `update`, not for `end`
 * (device D1-7: an `end` alert played none, docs/research/2026-11-07-live-activity-end-sound.md), so the sound rides this push; the
 * Lock Screen card lights up and there is no separate banner (TDD §3 notify). Apple puts `sound` inside the Live Activity `alert`.
 */
export function buildLiveActivityDone(params: {
  topic: string;
  memo: Memo;
  summary: Summary;
  now: Date;
}): ApnsMessage {
  const { topic, memo, summary, now } = params;
  return {
    headers: { topic: `${topic}.push-type.liveactivity`, pushType: "liveactivity", priority: 10 },
    payload: {
      aps: {
        timestamp: epochSeconds(now),
        event: "update",
        "content-state": contentState({ memo, phase: "done", headline: summary.headline }),
        alert: {
          title: kindChip(memo.kind) ?? "Iris",
          body: truncate(summary.headline, ALERT_BODY_MAX),
          sound: "default",
        },
      },
    },
  };
}

/**
 * The end, sent after `buildLiveActivityDone` and without an alert: the final state and `dismissal-date`. Its timestamp is one second
 * after `now` so the system, which shows the most recent timestamp, never treats it as older than the done update.
 */
export function buildLiveActivityEnd(params: {
  topic: string;
  memo: Memo;
  summary: Summary;
  now: Date;
}): ApnsMessage {
  const { topic, memo, summary, now } = params;
  return {
    headers: { topic: `${topic}.push-type.liveactivity`, pushType: "liveactivity", priority: 10 },
    payload: {
      aps: {
        timestamp: epochSeconds(now) + 1,
        event: "end",
        "dismissal-date": epochSeconds(new Date(now.getTime() + DISMISS_AFTER_MS)),
        "content-state": contentState({ memo, phase: "done", headline: summary.headline }),
      },
    },
  };
}

/**
 * Headline only, never transcript or reply text (TDD §12). The collapse id is the memo id (36
 * bytes, APNs allows 64), so a re-send after a partial notify failure replaces the banner.
 */
export function buildAlert(params: { topic: string; memo: Memo; summary: Summary }): ApnsMessage {
  const { topic, memo, summary } = params;
  const payload: AlertPayloadBody = {
    aps: {
      alert: {
        title: kindChip(memo.kind) ?? "Iris",
        body: truncate(summary.headline, ALERT_BODY_MAX),
      },
      "mutable-content": 1,
      category: "MEMO_DONE",
      "thread-id": "memo",
      sound: "default",
    },
    memo: memo.id,
  };
  return {
    headers: { topic, pushType: "alert", priority: 10, collapseId: memo.id },
    payload,
  };
}
