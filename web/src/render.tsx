import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { parsePayload } from "./payload";
import { applyTheme } from "./theme";

declare global {
  interface Window {
    iris: { render(payload: unknown): void };
  }
}

/** Installs `window.iris.render` on the page; the host calls it once after load and again on change. */
export function install(container: HTMLElement): void {
  const root = createRoot(container);
  let generation = 0;
  window.iris = {
    render(raw) {
      const payload = parsePayload(raw);
      if (payload) applyTheme(payload.theme);
      generation += 1;
      flushSync(() => root.render(<App raw={raw} generation={generation} />));
    },
  };
}
