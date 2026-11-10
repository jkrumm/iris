import type { Page } from "@playwright/test";

export const SHOW_FIXTURES = [
  "table",
  "chart-bar",
  "chart-line",
  "chart-area",
  "chart-pie",
  "stat",
  "list",
  "callout",
] as const;
export const ALL_FIXTURES = [
  ...SHOW_FIXTURES,
  "markdown",
  "html",
  "invalid-spec",
  "invalid-payload",
] as const;
export type Scheme = "light" | "dark";

export const visual = process.env.WEB_VISUAL !== "0";

/** Opens the harness page bare (no controls) and renders one fixture through window.iris.render. */
export async function openFixture(
  page: Page,
  name: string,
  scheme: Scheme = "light",
  width = "full",
) {
  await page.goto(`/harness/harness.html?fixture=${name}&scheme=${scheme}&width=${width}`);
  await settled(page);
}

/** The render is synchronous; this waits for fonts, the sandboxed frame and a chart's first paint. */
export async function settled(page: Page) {
  await page.waitForFunction(() => (document.getElementById("root")?.children.length ?? 0) > 0);
  await page.evaluate(() => document.fonts.ready);
  const frame = await page
    .locator("iframe")
    .first()
    .elementHandle({ timeout: 500 })
    .catch(() => null);
  if (frame) await (await frame.contentFrame())?.waitForLoadState("load");
  await page.evaluate(
    () =>
      new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))),
  );
}

/**
 * Stand-in for the host's injected script (see docs/research/2026-11-webview-island.md): a ResizeObserver on <html>
 * and <body> measuring documentElement.getBoundingClientRect().height, recorded on window.__heights.
 */
export async function installHostStandIn(page: Page) {
  await page.addInitScript(() => {
    const heights: number[] = [];
    (window as unknown as { __heights: number[] }).__heights = heights;
    const measure = () => {
      const height = Math.ceil(document.documentElement.getBoundingClientRect().height);
      if (heights.at(-1) !== height) heights.push(height);
    };
    document.addEventListener("DOMContentLoaded", () => {
      const observer = new ResizeObserver(measure);
      observer.observe(document.documentElement);
      observer.observe(document.body);
      measure();
    });
    (window as unknown as { __measure: () => void }).__measure = measure;
  });
}
