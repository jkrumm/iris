import { expect, test } from "@playwright/test";
import { ALL_FIXTURES, openFixture, visual, type Scheme } from "./helpers";

// Baselines are Linux renders (make web-snapshots); other hosts skip the comparison (WEB_VISUAL=0).
test.skip(!visual, "visual baselines are Linux-only (WEB_VISUAL=0)");

const SCREENSHOT_FIXTURES = ALL_FIXTURES.filter((name) => name !== "invalid-payload");

for (const scheme of ["light", "dark"] as Scheme[]) {
  for (const name of SCREENSHOT_FIXTURES) {
    test(`${name} ${scheme}`, async ({ page }) => {
      await openFixture(page, name, scheme);
      await expect(page.locator("#root")).toHaveScreenshot(`${name}-${scheme}.png`);
    });
  }
}
