# web/ (the artifact page the WebView island loads)

One static page (Vite, React 19, strict TypeScript, bun) that the iOS and Mac WebView island loads from the app bundle. The host calls `window.iris.render({artifact, theme})` after load and on change (`src/render.tsx`). Contracts, CSP reasoning, library choices and measurements: `docs/web-renderer.md`; read it before changing the CSP, the bundle shape or a library. Host side: `apple/Packages/IrisUI/AGENTS.md`.

## Build and check

- The bundle is committed. After any change under `web/` run `make web-build` and commit the result with the source: `make check-web` fails on drift ("run make web-build") and above the 1.5 MB gzip budget.
- Builds are byte-reproducible (exact dependency pins, `bun.lock`, no path or time embedded), so the Linux build equals the macOS one; keep it so.
- Screenshot baselines in `tests/__screenshots__/` are Linux renders. Re-record only with `make web-snapshots`; the Playwright image tag is `PLAYWRIGHT_VERSION` in the Makefile and must move with the pinned `@playwright/test`.
- `WEB_E2E=0` skips the Playwright e2e in `make check-web` (the lead tier does); screenshots compare only with `WEB_VISUAL=1`.
- `bun run dev` serves a harness (never in the bundle) that renders every `contracts/` fixture plus `web/fixtures/`. `src/dev/theme.ts` mirrors the host's token values, and a test compares its key set with `ArtifactTheme.swift`.

## Rules of the page

- The page styles itself with `var(--iris-*)` only; the host sets those variables on `<html>`. Use no `prefers-color-scheme` and no viewport units.
- The page carries no bridge code: the host injects it in an isolated world (`height`, `ready`). Keep `html, body {height: auto; overflow: hidden; margin: 0; background: transparent}` and document height equal to content height; the island has no inner scroll, so nothing is `overflow: auto`.
- The CSP in `index.html` allows no inline `<script>` or `<style>`, no `style="…"` text at runtime (React style objects and Chart.js use CSSOM), no `eval` or `new Function`.
- The host serves only flat names `[A-Za-z0-9._-]+`: the build is one classic IIFE script (no `type="module"`, no `crossorigin`) with unhashed names `index.html`, `artifact.js`, `artifact.css`, `KaTeX_*.woff2`, relative URLs and no sourcemaps (`vite.config.ts` plugins `classicScript`, `katexWoff2Only`).
- A bad payload or invalid spec renders one notice (`src/messages.ts`), never throws and never shows spec content.
- Show specs validate against `contracts/schema/artifacts.show-spec.json` plus the zod refinements JSON Schema cannot express (`src/spec.ts`).
- Markdown never passes raw HTML (no `rehype-raw`); only `data:image/` images render. Do not add `rehype-raw`, `streamdown` or shiki: the size budget and the no-raw-HTML rule rule them out.
- HTML documents do not reach this page in the apps: the host serves them through its own `.html` entry. `src/doc/HtmlDoc.tsx` stays a sandboxed `srcdoc` iframe with no script.
- Charts register only the Chart.js controllers and elements they use; `lowlight` is aliased to `src/doc/lowlight-lite.ts` to keep 37 languages out of the bundle.
