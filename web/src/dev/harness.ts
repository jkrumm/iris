// DEV ONLY. `/harness.html` lists every fixture; `?fixture=<name>&scheme=light|dark` renders one bare (the screenshots).
import "katex/dist/katex.min.css";
import "../styles.css";
import "./harness.css";
import { install } from "../render";
import type { Scheme } from "../payload";
import { fixtures } from "./fixtures";
import { devTheme } from "./theme";

const params = new URLSearchParams(location.search);
const root = document.getElementById("root");
if (!root) throw new Error("missing #root");
install(root);

const names = Object.keys(fixtures);
const state = {
  fixture: params.get("fixture") ?? names[0] ?? "",
  scheme: (params.get("scheme") === "dark" ? "dark" : "light") as Scheme,
  width: params.get("width") ?? (params.has("fixture") ? "full" : "390"),
};

const frame = document.getElementById("frame");

function show() {
  const artifact = fixtures[state.fixture];
  if (!artifact) return;
  if (frame) frame.style.width = state.width === "full" ? "100%" : `${state.width}px`;
  window.iris.render({ artifact, theme: devTheme(state.scheme) });
}

function controls() {
  const bar = document.getElementById("chrome");
  if (!bar) return;
  const select = (label: string, options: string[], value: string, set: (v: string) => void) => {
    const wrap = document.createElement("label");
    wrap.textContent = `${label} `;
    const el = document.createElement("select");
    for (const option of options) el.add(new Option(option, option, false, option === value));
    el.addEventListener("change", () => {
      set(el.value);
      show();
    });
    wrap.append(el);
    bar.append(wrap);
  };
  select("fixture", names, state.fixture, (v) => (state.fixture = v));
  select("scheme", ["light", "dark"], state.scheme, (v) => (state.scheme = v as Scheme));
  select("width", ["390", "600", "900", "full"], state.width, (v) => (state.width = v));
}

if (!params.has("fixture")) controls();
else document.getElementById("chrome")?.remove();
show();
