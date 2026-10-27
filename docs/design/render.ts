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
  { name: "history-light", page: "history", scheme: "light", size: PHONE },
  { name: "history-dark", page: "history", scheme: "dark", size: PHONE },
  { name: "detail-light", page: "detail", v: "done", scheme: "light", size: PHONE },
  { name: "detail-dark", page: "detail", v: "done", scheme: "dark", size: PHONE },
  { name: "detail-failed-dark", page: "detail", v: "failed", scheme: "dark", size: PHONE },
  { name: "record-light", page: "record", v: "take", scheme: "light", size: PHONE },
  { name: "record-dark", page: "record", v: "take", scheme: "dark", size: PHONE },
  { name: "record-mic-dark", page: "record", v: "mic", scheme: "dark", size: PHONE },
  { name: "record-mode-light", page: "record", v: "mode", scheme: "light", size: PHONE },
  { name: "lockscreen-idle", page: "lockscreen", v: "idle", scheme: "dark", size: PHONE },
  { name: "lockscreen-recording", page: "lockscreen", v: "recording", scheme: "dark", size: PHONE },
  { name: "lockscreen-processing", page: "lockscreen", v: "processing", scheme: "dark", size: PHONE },
  { name: "lockscreen-done", page: "lockscreen", v: "done", scheme: "dark", size: PHONE },
  { name: "lockscreen-needs-route", page: "lockscreen", v: "needs-route", scheme: "dark", size: PHONE },
  { name: "lockscreen-done-light", page: "lockscreen", v: "done", scheme: "light", size: PHONE },
  { name: "island", page: "island", scheme: "dark", size: [402, 1060] },
  { name: "notification-done-dark", page: "notification", v: "done", scheme: "dark", size: PHONE },
  { name: "notification-done-light", page: "notification", v: "done", scheme: "light", size: PHONE },
  { name: "notification-needs-route-dark", page: "notification", v: "needs-route", scheme: "dark", size: PHONE },
  { name: "mac-panel-light", page: "mac", v: "panel", scheme: "light", size: MAC },
  { name: "mac-panel-dark", page: "mac", v: "panel", scheme: "dark", size: MAC },
  { name: "mac-menu-dark", page: "mac", v: "menu", scheme: "dark", size: MAC },
  { name: "mac-notify-light", page: "mac", v: "notify", scheme: "light", size: MAC },
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
