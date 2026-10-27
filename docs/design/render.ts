// Renders every mockup surface to PNG with headless Chrome (device-sized viewport, 2x).
// Usage: bun docs/design/render.ts [name-substring]   Output: docs/design/renders/ (gitignored)
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const root = fileURLToPath(new URL("./", import.meta.url));
const out = `${root}renders`;
const PHONE = [402, 874] as const;
const MAC = [1440, 900] as const;

type Shot = { name: string; page: string; v?: string; scheme: "light" | "dark"; size: readonly [number, number] };
const shots: Shot[] = [
  // Round 1, surfaces unchanged in round 2 (Lock Screen). The other round-1 renders stay on disk as the cross-reference.
  { name: "lockscreen-idle", page: "lockscreen", v: "idle", scheme: "dark", size: PHONE },
  { name: "lockscreen-recording", page: "lockscreen", v: "recording", scheme: "dark", size: PHONE },
  { name: "lockscreen-processing", page: "lockscreen", v: "processing", scheme: "dark", size: PHONE },
  { name: "lockscreen-done", page: "lockscreen", v: "done", scheme: "dark", size: PHONE },
  { name: "lockscreen-needs-route", page: "lockscreen", v: "needs-route", scheme: "dark", size: PHONE },
  { name: "lockscreen-done-light", page: "lockscreen", v: "done", scheme: "light", size: PHONE },
  // Round 2
  { name: "r2-detail-light", page: "detail", v: "done", scheme: "light", size: PHONE },
  { name: "r2-detail-dark", page: "detail", v: "done", scheme: "dark", size: PHONE },
  { name: "r2-detail-steps-light", page: "detail", v: "steps", scheme: "light", size: PHONE },
  { name: "r2-detail-steps-dark", page: "detail", v: "steps", scheme: "dark", size: PHONE },
  { name: "r2-detail-cost-dark", page: "detail", v: "cost", scheme: "dark", size: PHONE },
  { name: "r2-detail-failed-dark", page: "detail", v: "failed", scheme: "dark", size: PHONE },
  { name: "r2-diagnostics-light", page: "settings", v: "diagnostics", scheme: "light", size: PHONE },
  { name: "r2-diagnostics-dark", page: "settings", v: "diagnostics", scheme: "dark", size: PHONE },
  { name: "r2-diagnostics-copied-dark", page: "settings", v: "copied", scheme: "dark", size: PHONE },
  { name: "r2-island", page: "island", v: "single", scheme: "dark", size: [402, 1060] },
  { name: "r2-island-two", page: "island", v: "two", scheme: "dark", size: [402, 1060] },
  { name: "r2-notification-done-dark", page: "notification", v: "done", scheme: "dark", size: PHONE },
  { name: "r2-notification-done-light", page: "notification", v: "done", scheme: "light", size: PHONE },
  { name: "r2-notification-needs-route-dark", page: "notification", v: "needs-route", scheme: "dark", size: PHONE },
  { name: "r2-mac-panel-light", page: "mac", v: "panel", scheme: "light", size: MAC },
  { name: "r2-mac-panel-dark", page: "mac", v: "panel", scheme: "dark", size: MAC },
  { name: "r2-mac-menu-dark", page: "mac", v: "menu", scheme: "dark", size: MAC },
  { name: "r2-mac-notify-light", page: "mac", v: "notify", scheme: "light", size: MAC },
  { name: "r2-mac-notify-reply-dark", page: "mac", v: "notify-reply", scheme: "dark", size: MAC },
  { name: "r2-record-light", page: "record", v: "take", scheme: "light", size: PHONE },
  { name: "r2-record-dark", page: "record", v: "take", scheme: "dark", size: PHONE },
  { name: "r2-record-mic-dark", page: "record", v: "mic", scheme: "dark", size: PHONE },
  { name: "r2-record-mode-light", page: "record", v: "mode", scheme: "light", size: PHONE },
  { name: "r2-record-chat-dark", page: "record", v: "chat", scheme: "dark", size: PHONE },
  { name: "r2-chat-answer-light", page: "chat", v: "answer", scheme: "light", size: PHONE },
  { name: "r2-chat-answer-dark", page: "chat", v: "answer", scheme: "dark", size: PHONE },
  { name: "r2-compose-light", page: "compose", v: "typing", scheme: "light", size: PHONE },
  { name: "r2-compose-dark", page: "compose", v: "typing", scheme: "dark", size: PHONE },
  { name: "r2-history-light", page: "history", v: "list", scheme: "light", size: PHONE },
  { name: "r2-history-dark", page: "history", v: "list", scheme: "dark", size: PHONE },
  { name: "r2-history-filters-light", page: "history", v: "filters", scheme: "light", size: PHONE },
  { name: "r2-history-filters-dark", page: "history", v: "filters", scheme: "dark", size: PHONE },
  { name: "r2-history-filter-sheet-dark", page: "history", v: "filter-sheet", scheme: "dark", size: PHONE },
  { name: "r2-stats-day-light", page: "stats", v: "day", scheme: "light", size: PHONE },
  { name: "r2-stats-day-dark", page: "stats", v: "day", scheme: "dark", size: PHONE },
  { name: "r2-stats-week-dark", page: "stats", v: "week", scheme: "dark", size: PHONE },
  { name: "r2-threads-list-light", page: "threads", v: "list", scheme: "light", size: PHONE },
  { name: "r2-threads-list-dark", page: "threads", v: "list", scheme: "dark", size: PHONE },
  { name: "r2-threads-thread-light", page: "threads", v: "thread", scheme: "light", size: PHONE },
  { name: "r2-threads-thread-dark", page: "threads", v: "thread", scheme: "dark", size: PHONE },
  { name: "r2-threads-hold-dark", page: "threads", v: "hold", scheme: "dark", size: PHONE },
];

mkdirSync(out, { recursive: true });
const filter = Bun.argv[2];
for (const s of shots.filter((x) => !filter || x.name.includes(filter))) {
  const url = `file://${root}mockups/${s.page}.html?scheme=${s.scheme}${s.v ? `&v=${s.v}` : ""}`;
  const png = `${out}/${s.name}.png`;
  rmSync(png, { force: true });
  const proc = Bun.spawn(
    [
      CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
      `--window-size=${s.size[0]},${s.size[1]}`, "--virtual-time-budget=1500",
      `--screenshot=${out}/${s.name}.png`, url,
    ],
    { stdout: "ignore", stderr: "ignore" },
  );
  // Headless Chrome exits non-zero after a virtual-time screenshot; the file is the success signal.
  await proc.exited;
  console.log(`${existsSync(png) ? "ok  " : "FAIL"} ${s.name}.png`);
}
