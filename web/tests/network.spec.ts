import { expect, test } from "@playwright/test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ALL_FIXTURES, openFixture, settled } from "./helpers";

const dist = join(import.meta.dirname, "../dist");
const files = readdirSync(dist);
const contracts = join(import.meta.dirname, "../../contracts/fixtures");

test("the emitted index.html carries a deny-by-default CSP and nothing inline", () => {
  const html = readFileSync(join(dist, "index.html"), "utf8");
  expect(html).toMatch(/http-equiv="Content-Security-Policy"/);
  expect(html).toContain("default-src 'none'");
  expect(html).not.toMatch(/<style/i);
  expect(html).not.toMatch(/\sstyle=/i);
  expect(html).not.toMatch(/<script(?![^>]*\ssrc=)[^>]*>/i);
  expect(html).not.toContain('type="module"');
  expect(html).not.toContain("crossorigin");
});

test("the build is flat and stably named", () => {
  expect(files).toContain("index.html");
  expect(files).toContain("artifact.js");
  expect(files).toContain("artifact.css");
  for (const file of files) expect(file).toMatch(/^[A-Za-z0-9._-]+$/);
  for (const file of files.filter((f) => f !== "index.html" && !f.startsWith("artifact."))) {
    expect(file).toMatch(/^KaTeX_[A-Za-z0-9-]+\.woff2$/);
  }
});

test("page load and every fixture touch only same-origin build files; the network is blocked", async ({
  page,
  baseURL,
}) => {
  const origin = new URL(baseURL ?? "").origin;
  const requests: string[] = [];
  const violations: string[] = [];
  page.on("request", (request) => requests.push(request.url()));
  await page.addInitScript(() => {
    (window as unknown as { __violations: string[] }).__violations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      (window as unknown as { __violations: string[] }).__violations.push(
        `${event.violatedDirective} ${event.blockedURI}`,
      );
    });
  });

  // The production page, rendered with every contracts fixture and the document fixtures.
  await page.goto("/index.html");
  const payloads = [
    ...readdirSync(contracts)
      .filter((f) => f.startsWith("artifacts.show-spec."))
      .map((f) => ({ kind: "show", spec: JSON.parse(readFileSync(join(contracts, f), "utf8")) })),
    {
      kind: "doc",
      format: "markdown",
      content: readFileSync(join(import.meta.dirname, "../fixtures/doc-markdown.md"), "utf8"),
    },
    {
      kind: "doc",
      format: "html",
      content: readFileSync(join(import.meta.dirname, "../fixtures/doc-html.html"), "utf8"),
    },
  ];
  for (const scheme of ["light", "dark"]) {
    for (const artifact of payloads) {
      await page.evaluate(
        (payload) =>
          (window as unknown as { iris: { render(p: unknown): void } }).iris.render(payload),
        { artifact, theme: { scheme } },
      );
      await settled(page);
    }
  }
  const read = () =>
    page.evaluate(() => (window as unknown as { __violations: string[] }).__violations);
  violations.push(...(await read()));
  // The harness build runs the same code on its fixtures (a page load each: the list resets, so read it per page).
  for (const name of ALL_FIXTURES) {
    await openFixture(page, name, "dark");
    violations.push(...(await read()));
  }

  // The probe on a fresh load, so its violation is the only entry the page can have.
  await page.goto("/index.html");
  const probe = await page.evaluate(async () => {
    try {
      await fetch("https://example.com/");
      return "open";
    } catch {
      return "blocked";
    }
  });
  expect(probe).toBe("blocked");

  const external = requests.filter((url) => !url.startsWith("data:") && !url.startsWith("about:"));
  expect(external.length).toBeGreaterThan(0);
  for (const url of external) expect(new URL(url).origin).toBe(origin);
  expect(requests.some((url) => url.includes("example.com"))).toBe(false);

  const allowed = new Set([...files.map((f) => `/${f}`), "/", "/index.html"]);
  const harnessFiles = new Set(
    readdirSync(join(import.meta.dirname, "../dist-harness")).map((f) => `/harness/${f}`),
  );
  for (const url of external) {
    const { pathname } = new URL(url);
    expect(allowed.has(pathname) || harnessFiles.has(pathname), pathname).toBe(true);
  }
  // KaTeX math: rehype-katex parses KaTeX's HTML into an inert template, whose `style` attributes the policy reports as
  // `style-src-attr`; the DOM React builds from it uses CSSOM and is clean (tests/csp.spec.ts pins that). Nothing else may be reported.
  expect(violations.filter((v) => !v.startsWith("style-src-attr"))).toEqual([]);
  // The probe is the only violation the page itself causes (reported once per policy: the header and the meta tag).
  expect(new Set(await read())).toEqual(new Set(["connect-src https://example.com/"]));
});
