# Mockup feedback — round 1 (owner, 2026-10-27)

The owner reviewed all 23 renders. Overall verdict: "Sieht doch alles schon mal nicht so schlecht aus." The basalt-ui
colours and the native Liquid Glass touch are right. The changes below are decisions; the fleet applies them in design
round 2 and in the screens.

## Keep

- History (sharper on mobile than in the Mac menu-bar window), the tinted needs-route row on top (Q1: yes).
- Record screen, mic picker, route-rule card, Auto mode first.
- Lock Screen flow: recording → processing → done → [Play] / reply, and the needs-route counter-question.
- Live Activity actions Play / Reply / Open (Q2: keep all three).
- Cost on the Lock Screen (Q3: keep for now). Add a Settings toggle to hide it.
- Record mode row (Q4: fine).

## Change

| Surface | Change |
|-|-|
| Memo detail | Less shadow on the bubbly buttons. Telemetry isn't shown by default. |
| Memo detail player | Scrubbable, plus a **10 s back** button. |
| Memo detail steps | A **waterfall**: each step's bar starts where the previous one ended. Show each step against its usual duration (faster/slower than the median). **Collapsed by default**, opened on demand. |
| Memo detail trace id | **Not visible.** Keep it only behind Settings → Diagnostics (copy for debugging). |
| Dynamic Island | Replace the "Switch mic" text with an icon button (a mic-swap symbol). Keep pause. Design the case of two memos in a row. |
| Notification | Actions can be smaller and side by side. |
| Mac | The hotkey must differ from the owner's existing input-box dictation key. The Mac notification needs **Reply** too. |
| Record, tab chip | A pre-chosen herdr tab (`dotfiles`) is rarely needed; the owner names the project while speaking. Keep it, but de-emphasize it. Most herdr-bound memos target the orchestration queue / the factory, a later routing refinement. |

## New

- **Chat mode:** a plain conversation with an agent, Perplexity-style, with no implied action (no todo, no journal). It gets
  an answer, rendered and optionally spoken, in a thread.
- **Typing fallback:** enter a memo as text when speaking isn't possible.
- **History filters:** filter by route/classification, not only search.
- **Stats:** what I do how often, over time (volume per route, per day/week, trends).
- **Threads view:** not designed yet; needs its own mockup.

## Housekeeping

Renders (`docs/design/renders/`, gitignored), the MacBook gallery (`iumac:/tmp/iris-mockups.html`) and the 23 private
image objects stay as the cross-reference until the R3 screens are built. Then delete all three (the image objects through
`/img`, not just by letting the links expire). This is a backlog item.
