// Builds the round-2 review gallery from renders/*.png: docs/design/renders/iris-mockups.html (gitignored).
// The page links images as `iris-mockups/<name>.png`, so copy it next to a sibling directory of the PNGs:
//   rsync renders/iris-mockups.html <host>:/tmp/iris-mockups.html && rsync -a --include='r2-*.png' --exclude='*' renders/ <host>:/tmp/iris-mockups/
// Usage: bun docs/design/gallery.ts
import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const out = fileURLToPath(new URL("./renders/", import.meta.url));
const have = new Set(readdirSync(out).map((f) => f.replace(/\.png$/, "")));

type Group = { title: string; note: string; shots: [name: string, caption: string][] };
const groups: Group[] = [
  { title: "Memo detail", note: "Less shadow, scrubbable player with 10 s back, steps as a waterfall (collapsed by default), cost collapsed, no trace id.", shots: [
    ["r2-detail-light", "done, steps collapsed, light"], ["r2-detail-dark", "done, steps collapsed, dark"],
    ["r2-detail-steps-light", "waterfall open, light"], ["r2-detail-steps-dark", "waterfall open, dark"],
    ["r2-detail-cost-dark", "cost open"], ["r2-detail-failed-dark", "failed, waterfall open"] ] },
  { title: "Settings → Diagnostics", note: "Trace id with copy, hide-cost-on-Lock-Screen toggle.", shots: [
    ["r2-diagnostics-light", "light"], ["r2-diagnostics-dark", "dark"], ["r2-diagnostics-copied-dark", "after copy"] ] },
  { title: "Dynamic Island", note: "Mic-swap icon button, pause kept, two memos in a row.", shots: [
    ["r2-island", "single memo, four states"], ["r2-island-two", "two memos in a row"] ] },
  { title: "Notification card", note: "Smaller actions, side by side.", shots: [
    ["r2-notification-done-dark", "done, dark"], ["r2-notification-done-light", "done, light"], ["r2-notification-needs-route-dark", "needs route, dark"] ] },
  { title: "Mac", note: "New hotkey, Reply on the notification.", shots: [
    ["r2-mac-panel-light", "panel, light"], ["r2-mac-panel-dark", "panel, dark"], ["r2-mac-menu-dark", "menu-bar window"],
    ["r2-mac-notify-light", "notification"], ["r2-mac-notify-reply-dark", "notification, Reply open"] ] },
  { title: "Record", note: "Tab chip de-emphasized, Chat mode, keyboard entry point.", shots: [
    ["r2-record-light", "take, light"], ["r2-record-dark", "take, dark"], ["r2-record-mic-dark", "mic picker"],
    ["r2-record-mode-light", "mode sheet with Chat"], ["r2-record-chat-dark", "Chat mode selected"] ] },
  { title: "Chat mode", note: "A plain conversation, rendered answer, spoken on demand.", shots: [
    ["r2-chat-answer-light", "answered thread, light"], ["r2-chat-answer-dark", "answered thread, dark"] ] },
  { title: "Typed memo", note: "The fallback when speaking isn't possible.", shots: [
    ["r2-compose-light", "composer, light"], ["r2-compose-dark", "composer, dark"] ] },
  { title: "History", note: "Route and state filters; Stats tab in the dock.", shots: [
    ["r2-history-light", "list, light"], ["r2-history-dark", "list, dark"],
    ["r2-history-filters-light", "filters on, light"], ["r2-history-filters-dark", "filters on, dark"], ["r2-history-filter-sheet-dark", "filter sheet"] ] },
  { title: "Stats", note: "Volume per route per day and per week, trends.", shots: [
    ["r2-stats-day-light", "days, light"], ["r2-stats-day-dark", "days, dark"], ["r2-stats-week-dark", "weeks, dark"] ] },
  { title: "Threads", note: "List, one thread rendered as markdown, hold-to-talk.", shots: [
    ["r2-threads-list-light", "list, light"], ["r2-threads-list-dark", "list, dark"],
    ["r2-threads-thread-light", "thread, light"], ["r2-threads-thread-dark", "thread, dark"], ["r2-threads-hold-dark", "hold to talk"] ] },
];

const missing: string[] = [];
const sections = groups.map((g) => {
  const figs = g.shots.map(([n, cap]) => {
    if (!have.has(n)) { missing.push(n); return ""; }
    const wide = n.startsWith("r2-mac-");
    return `<figure class="${wide ? "wide" : ""}"><a href="iris-mockups/${n}.png" target="_blank"><img loading="lazy" src="iris-mockups/${n}.png" alt="${n}"></a><figcaption><b>${n}</b><br>${cap}</figcaption></figure>`;
  }).join("");
  return `<section><h2>${g.title}</h2><p>${g.note}</p><div class="row">${figs}</div></section>`;
}).join("\n");

writeFileSync(`${out}iris-mockups.html`, `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Iris — mockups, round 2</title>
<style>
  body { margin: 0; padding: 32px 40px 80px; background: #17171a; color: #e5e5e9; font: 15px/1.4 -apple-system, "Helvetica Neue", sans-serif; }
  h1 { font-size: 28px; margin: 0 0 4px; } .lead { color: #a7a7aa; margin: 0 0 28px; }
  section { margin-bottom: 44px; } h2 { font-size: 20px; margin: 0; } section > p { color: #a7a7aa; margin: 2px 0 14px; }
  .row { display: flex; gap: 22px; flex-wrap: wrap; align-items: flex-start; }
  figure { margin: 0; width: 300px; } figure.wide { width: 620px; }
  img { width: 100%; display: block; border-radius: 18px; box-shadow: 0 0 0 1px #333; }
  figcaption { font-size: 12px; color: #a7a7aa; padding-top: 8px; } figcaption b { color: #e5e5e9; font-weight: 600; }
</style></head><body>
<h1>Iris — mockups, round 2</h1><p class="lead">Applies feedback-round-1. Light and dark per surface. Click an image for full size.</p>
${sections}
</body></html>`);
console.log(`gallery: ${groups.reduce((n, g) => n + g.shots.length, 0) - missing.length} images${missing.length ? `, MISSING: ${missing.join(", ")}` : ""}`);
