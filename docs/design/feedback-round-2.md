# Mockup feedback — round 2 (owner, 2026-10-27 night)

Verdict: "Wir sind auf einem guten Weg." The basalt-ui colours and the Liquid Glass touch stay. Binding for the screens,
alongside round 1 (where the two conflict, this file wins).

## Decisions

**Memo detail**
- **Player:** go back to round 1's layout: play/pause on the left, the scrubbable timeline, and **one 10 s-back icon on the
  right**. No playback speed.
- **Step waterfall:**
  - bars span the full width like a bottom border (not inset from the left and right);
  - **duration and cost unified in one metric chip** per step (e.g. `1.8 s · $0.004`);
  - drop the collapse arrow if that buys room; collapsed-by-default stays only if it still reads well.
- **Faster/slower than usual:** show it only where a meaningful baseline exists (the same step and route, enough
  samples). Otherwise leave it out. No fake precision.
- **Bottom actions:** icon-only (play, reply, retry), no text labels.
- **Retries** are visible per step. The server already retries transient failures twice with exponential backoff (TDD §3).
  The UI shows the attempt count and keeps [Retry from step] for manual retries.

**Settings / Diagnostics**
- **Entry point:** give Diagnostics an obvious one (a Settings row).
- **Copy:** copy the **memo id** (that's the debugging handle; the trace id equals it). The copy animates to "Copied".
- **Drop the hide-cost toggle**, which reverses round 1. Cost is fine everywhere.
- **The outbox holds whole memos and chat messages waiting to send**, not just segments. Show it as a queue of items.

**Motion and colour (applies everywhere)**
- **Animations:** thought-through animations that explain state, e.g. the processing steps advancing one by one, the copy
  feedback, queued memos. Subtle and professional, never playful.
- **Colour must earn its place.** Prefer the restrained, professional look.

**Lock Screen / Dynamic Island / notifications**
- **Dynamic Island:** the icon controls (stop, mic swap, pause) are right. Animate the step progress.
- **Queues:** supporting several queued memos (the first one's status plus the next one already explained) is good. Keep
  it.
- **Done card:** the misaligned checkmark next to the headline is a mockup rendering bug; it must sit aligned in the real
  view.
- **Reply on the iPhone:** design it. The notification-card reply and the Mac reply exist; the iPhone reply flow is missing.

**Mac**
- **Menu-bar history:** match the mobile History rows (round 1's sharper look).

**Chat and Threads rendering**
- **Content:** render whatever Hermes streams: markdown, **syntax-highlighted code**, **Mermaid diagrams** and SVG.
  **Tables** collapse to cards on narrow widths.
- **Streaming:** smooth, final-answer only (Hermes is configured to skip thinking/chatter; Iris doesn't add any).
- **Mermaid library:** the owner mentioned "a new library from Obsidian" for Mermaid rendering, name unclear. Research the
  options (`/research`) before choosing; native vs a WebView renderer is a TDD decision.

**History, Threads, filters**
- **Filters:** the bottom sheet that collapses up from the bottom is good. Stats is good. Typed memo is good.
- **Swipe actions on rows:**
  - swipe right: **done** (handled, moved out of the way); swipe further right: **favorite**;
  - swipe left: **archive**; swipe further left: **delete** (with undo).
- **Quick filters:** chips above the list (Favorites, Chats, Needs route, …) next to search/filter.
- **History vs Threads:** the owner couldn't tell them apart. **Decision (orchestrator's recommendation, adopted unless
  the owner objects):** drop the separate Threads tab. History is the one list of everything. A conversation (a Chat or a
  multi-turn Hermes thread) is a History row that opens the thread view, and the "Chats" quick filter shows only those.
  Tabs become History · Stats · Settings.

**Recording inside the app**
- **Start anywhere:** a recording can start from any screen.
- **While browsing:** the take continues as a **compact banner at the top**.
- **On leaving the app:** it moves into the Live Activity / Dynamic Island as before.

## Not changing

- **Hermes chat tagging:** Hermes rewrites unknown session sources to `api_server` (`_normalize_session_source`
  allow-list, TDD §3). The owner prefers Iris to own chat data (`threads.kind`). **No upstream Hermes patch.**
