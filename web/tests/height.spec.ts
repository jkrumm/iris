import { expect, test, type Page } from "@playwright/test";
import { ALL_FIXTURES, installHostStandIn, openFixture } from "./helpers";

// The host sizes the WebView to the document height and the island has no inner scroll: the document height must be
// the content's bottom edge, nothing may overflow-scroll, and a new payload changes the height.

const heights = (page: Page) =>
  page.evaluate(() => (window as unknown as { __heights: number[] }).__heights);

const contentBottom = (page: Page) =>
  page.evaluate(() => {
    const last = document.querySelector("#root")?.lastElementChild;
    return last ? last.getBoundingClientRect().bottom : 0;
  });

for (const width of [390, 900]) {
  for (const name of ALL_FIXTURES) {
    test(`${name} at ${width}px: height is the content, nothing scrolls`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await installHostStandIn(page);
      await openFixture(page, name, "light");
      await page.evaluate(() => (window as unknown as { __measure: () => void }).__measure());

      const bottom = await contentBottom(page);
      const reported = (await heights(page)).at(-1) ?? 0;
      expect(bottom).toBeGreaterThan(20);
      expect(reported).toBe(Math.ceil(bottom));

      // The host frames the WebView at the reported height: with that viewport there is nothing to scroll.
      await page.setViewportSize({ width, height: reported });
      const scroll = await page.evaluate(() => {
        const el = document.scrollingElement as HTMLElement;
        return {
          scrollHeight: el.scrollHeight,
          clientHeight: el.clientHeight,
          scrollWidth: el.scrollWidth,
          clientWidth: el.clientWidth,
        };
      });
      expect(scroll.scrollHeight).toBeLessThanOrEqual(scroll.clientHeight);
      expect(scroll.scrollWidth).toBeLessThanOrEqual(scroll.clientWidth);

      const scrollers = await page.evaluate(() =>
        [...document.querySelectorAll("*")]
          .filter((el) => {
            const style = getComputedStyle(el);
            return [style.overflowX, style.overflowY].some((v) => v === "auto" || v === "scroll");
          })
          .map((el) => el.tagName),
      );
      expect(scrollers).toEqual([]);
    });
  }
}

test("a different artifact changes the height", async ({ page }) => {
  await installHostStandIn(page);
  await openFixture(page, "callout", "light");
  await page.evaluate(() => (window as unknown as { __measure: () => void }).__measure());
  const before = (await heights(page)).at(-1) ?? 0;

  await page.evaluate(() => {
    const payload = {
      artifact: {
        kind: "show",
        spec: {
          type: "list",
          items: Array.from({ length: 12 }, (_, i) => ({
            text: `Item ${i + 1}`,
            detail: "Detail",
          })),
        },
      },
      theme: { scheme: "light" },
    };
    (window as unknown as { iris: { render(p: unknown): void } }).iris.render(payload);
  });
  await expect.poll(async () => (await heights(page)).at(-1) ?? 0).toBeGreaterThan(before + 100);
});
