import { expect, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { openFixture, SHOW_FIXTURES, settled } from "./helpers";
import { HOST_POLICY } from "./policy";

const swift = readFileSync(
  join(
    import.meta.dirname,
    "../../apple/Packages/IrisUI/Sources/IrisUI/Components/Artifact/ArtifactSchemeHandler.swift",
  ),
  "utf8",
);

/** The Swift string literal `static let bundledPolicy = "…" + "…"`, concatenated. */
function swiftBundledPolicy(): string {
  const declaration = /static let bundledPolicy =([\s\S]*?)\n\s*\/\/\//.exec(swift)?.[1] ?? "";
  return [...declaration.matchAll(/"([^"]*)"/g)].map((m) => m[1]).join("");
}

test("the test server sends the host's bundledPolicy, with 'self' for the iris-artifact: scheme", () => {
  const host = swiftBundledPolicy();
  expect(host).toContain("default-src 'none'");
  expect(HOST_POLICY).toBe(host.replaceAll("iris-artifact:", "'self'"));
});

test("the page's meta CSP lists the same origins as the host header", () => {
  const html = readFileSync(join(import.meta.dirname, "../index.html"), "utf8");
  expect(html).toContain("script-src 'self' iris-artifact:");
  expect(html).toContain("style-src 'self' iris-artifact:");
  expect(html).toContain("frame-src about:");
  expect(swift).toContain('"iris-artifact"');
});

test("an HTML document renders in a scriptless sandboxed frame under the host policy", async ({
  page,
}) => {
  await page.goto("/harness/harness.html?fixture=html&scheme=dark");
  await settled(page);

  const iframe = page.locator("iframe");
  await expect(iframe).toHaveAttribute("sandbox", "");
  await expect(iframe).toHaveAttribute("scrolling", "no");
  const frame = await (await iframe.elementHandle())?.contentFrame();
  expect(frame).toBeTruthy();
  // The frame is up (not blocked by frame-src) and shows the document's text, but no script ran.
  expect(await frame?.locator("h1").textContent()).toBe("Styled heading");
  // The document's script would append a <p>; its own source text does not count.
  expect(await frame?.locator("p").count()).toBe(0);
});

const headingStyle = async (frame: import("@playwright/test").Frame | null | undefined) =>
  frame?.locator("h1").evaluate((el) => {
    const style = getComputedStyle(el);
    return { color: style.color, fontSize: style.fontSize };
  });

test("FINDING: inline <style> in the srcdoc frame is blocked by the inherited policy", async ({
  page,
}) => {
  const document = readFileSync(join(import.meta.dirname, "../fixtures/doc-html.html"), "utf8");
  // Control: the same sandboxed srcdoc frame on a page without a policy applies the document's <style> (#4374a6, 24px).
  await page.goto("about:blank");
  await page.evaluate((srcdoc) => {
    // oxlint-disable-next-line react/iframe-missing-sandbox -- the sandbox attribute is set on the next line
    const frame = window.document.createElement("iframe");
    frame.setAttribute("sandbox", "");
    frame.srcdoc = srcdoc;
    window.document.body.append(frame);
  }, document);
  const control = await (await page.locator("iframe").elementHandle())?.contentFrame();
  await control?.waitForLoadState("load");
  expect(await headingStyle(control)).toEqual({ color: "rgb(67, 116, 166)", fontSize: "24px" });

  // Under the host's policy the frame inherits `style-src` without 'unsafe-inline': the document renders with browser defaults.
  await page.goto("/harness/harness.html?fixture=html&scheme=light");
  await settled(page);
  const frame = await (await page.locator("iframe").elementHandle())?.contentFrame();
  expect(await headingStyle(frame)).toEqual({ color: "rgb(0, 0, 0)", fontSize: "32px" });
});

const violationsOf = (page: import("@playwright/test").Page) =>
  page.evaluate(() => (window as unknown as { __violations: string[] }).__violations);

test.describe("no inline style under the policy", () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      (window as unknown as { __violations: string[] }).__violations = [];
      document.addEventListener("securitypolicyviolation", (event) => {
        (window as unknown as { __violations: string[] }).__violations.push(
          `${event.violatedDirective} ${event.blockedURI}`,
        );
      });
    });
  });

  for (const name of [...SHOW_FIXTURES, "invalid-spec", "invalid-payload", "html"]) {
    test(`${name}: React and Chart.js style through CSSOM only`, async ({ page }) => {
      await openFixture(page, name, "dark");
      expect(await violationsOf(page)).toEqual([]);
    });
  }

  test("markdown: only KaTeX's inert parse is reported, as style-src-attr", async ({ page }) => {
    await openFixture(page, "markdown", "dark");
    const violations = await violationsOf(page);
    expect(violations.length).toBeGreaterThan(0);
    expect(new Set(violations)).toEqual(new Set(["style-src-attr inline"]));
    // The rendered math still has its layout styles (applied through CSSOM).
    expect(
      await page
        .locator(".katex .strut")
        .first()
        .evaluate((el) => (el as HTMLElement).style.height),
    ).not.toBe("");
  });
});
