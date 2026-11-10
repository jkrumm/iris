# A sandboxed WebView island in IrisUI (Issue 644)

Measured 2026-11-10 on the mini: Xcode 27.1 (Swift 6.4), iOS simulator iPhone 17 iOS 27.0, `IrisMac` Debug on macOS. The code is `apple/Packages/IrisUI/Sources/IrisUI/Components/Artifact/`, the
test page `Resources/Artifact/island.{html,css,js}`. Artifacts render in this island: the next rows (`web-renderer`, the inline artifact views) build on it.

## Verdict

**The SwiftUI `WebView` / `WebPage` API (iOS and macOS 26) does everything the island needs; `WKWebView` is not needed.** The one `WKWebView` touch is a Mac-only verification aid (below).
The height comes from a bridge: a `ResizeObserver` in an isolated content world posts it to a script-message handler, with a timer and a Swift-side re-measure as fallbacks.
Each island costs about **13 MB** of WebKit memory on the Mac and its own WebContent process.

| Need | How it is met |
|-|-|
| Load offline, no server | `WebPage.Configuration.urlSchemeHandlers[URLScheme("iris-artifact")]`: a `URLSchemeHandler` returns the bundled file (`iris-artifact://app/<flat file>`) or the island's own HTML string (`iris-artifact://doc/page`). No network, no localhost. |
| Sandbox | Every response carries a CSP. Bundled page: `default-src 'none'; script-src iris-artifact:; style-src iris-artifact:; img-src iris-artifact: data:; font-src iris-artifact:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`. A generated `.html` document gets inline styles and no script. A `fetch("https://example.com/")` from the page is rejected (the page prints `network: blocked`, asserted in a test, visible in every screenshot). The data store is `.nonPersistent()`. |
| Navigation | `WebPage.NavigationDeciding` runs `ArtifactNavigationPolicy`: the island's own scheme and `about:blank` load; an http(s)/mailto/tel **link activation in the main frame** is cancelled and handed to `openURL` (the system browser); anything else (a script's `location.href`, a redirect, a form, `file:`, `javascript:`, `data:`, `blob:`, a subframe) is cancelled. |
| Script bridge | `Configuration.userContentController` is a `WKUserContentController`: `add(handler, contentWorld:, name: "iris")` works on a `WebPage`. The bridge script is a `WKUserScript` in the isolated world `iris-bridge`, so page scripts (and generated HTML) cannot see or tamper with it, and CSP does not block it. |
| Payload, one typed call | `ArtifactWebView(entry:payload:)` encodes an `Encodable` to JSON; after `ready` the island runs `window.iris.render(JSON.parse(payload))` in the page world through `page.callJavaScript(..., arguments: ["payload": json], contentWorld: .page)`. Generated HTML has no script: `render` is a no-op for it. |
| Theme | `ArtifactTheme` writes the Theme tokens as `--iris-*` CSS variables (colors as `rgb()` of the resolved light or dark value, radii, spacing, text sizes, font stacks, `color-scheme`) on `<html>` at document start, so there is no unthemed first frame; a change of `colorScheme` re-applies them with `callJavaScript` in the bridge world. The page uses only `var(--iris-*)`: no `prefers-color-scheme` query. |
| Height | below |
| Full screen | A corner button presents the same entry and payload in a second island (`.fullScreenCover` on iOS, a sheet on the Mac); a `WebPage` cannot sit in two `WebView`s. The full-screen island scrolls. Compiled and wired; **not exercised by a screenshot or test**. |

## Bridge contract (what `web-renderer` must follow)

Handler name **`iris`** (`window.webkit.messageHandlers.iris`, isolated world only). The page needs no bridge code of its own: the injected script posts
`{type: "height", value: <CSS px, ceil>}` whenever the document height changes by 1 px or more, and `{type: "ready"}` once, after the first measure. The page defines
`window.iris = { render(payload) {…} }`; Swift calls it once after `ready` and again when the payload changes. `html` and `body` get `height: auto; overflow: hidden` from the bridge (inline islands),
so a page must not size itself from the viewport (`100vh`) and must keep the document height equal to its content (margins count).

## Height mechanism

`ResizeObserver` on `<html>` and `<body>`, measured as `documentElement.getBoundingClientRect().height`, reported through `requestAnimationFrame` **and** a 120 ms timer (whichever first); SwiftUI frames the `WebView` at that height with `.scrollDisabled(true)`, so the island has no inner scroll.
Swift also calls `window.__irisMeasure()` (`ArtifactIsland.refreshHeight`) after the load, after each payload render and when the scene becomes active.
The SwiftUI scroll geometry (`webViewOnScrollGeometryChange`, content size) is wired as a diagnostic (`scrollContentHeight`) and drives nothing; I did not compare its numbers with the bridge's.

**Occluded Mac window (found the hard way).** The first Mac snapshot (animation frames only) stayed at 24 pt: the empty page's height, never updated. WebKit gives a window it treats as occluded no rendering updates, so neither `requestAnimationFrame` nor
`ResizeObserver` callbacks fire. Measuring forces layout, so the timer and the Swift re-measure work there: the island then reached 282 pt (iOS: 283 pt). **But WebKit also does not paint into such a window**: the window server's picture of the island was an empty frame at the right height. The Mac PNGs
here overlay the web view's own `takeSnapshot` (an `NSImageView` over the `WKWebView` found in the window, `MacArtifactSnapshot.swift`); `WebPage` has no snapshot API. A real, visible window paints normally; this affects only the mini's headless display.

First load on a freshly erased simulator under host load (1-minute load average above 50) took longer than 6 s to reach the first measure and less than 16 s; the proof waits 16 s. The `ready` / `height` log lines
(`com.jkrumm.iris`, category `artifact`) carry the time since the island was created. Before the first measure the island is 120 pt high (`placeholderHeight`), or the last measured height of the same `id` (`ArtifactHeightCache`).

## Memory

Mac, `IrisMac` Debug, `ArtifactIslandDemo(islands: n)` in one scroll view, all islands alive at once, 6 s after the window opened. WebKit footprint is the sum of `footprint -p` over the WebContent processes that appeared since the baseline;
the app column is this process's `phys_footprint`.

| Islands | WebContent processes | WebContent footprint | App footprint (baseline 85.3 MB) |
|-|-|-|-|
| 1 | 1 | 13 MB | 85.3 MB |
| 5 | 5 | 66 MB | 87.2 MB |
| 10 | 10 | 139 MB | 89.0 MB |

About **13 MB and one process per island**, linear; the app itself grows by under 0.4 MB per island. Other proof runs gave 12 to 14 MB for one and 120 to 139 MB for ten. Every island has its own `nonPersistent()` data store, which probably is why none share a process;
a shared store was not tried. The numbers are for the small test page (a few DOM nodes, one SVG); a chart library will add its own heap.

iOS (simulator): the WebContent processes are host processes and `footprint` reads 0 for them, so the file falls back to resident size: 256 MB for one island, 1.16 GB for five, 2.2 GB for ten. That is mostly shared system mappings, not a per-island cost, so
**iOS memory per island is not measured**. It needs the phone (`make device`), where one WebContent process per island will also meet iOS's per-process limits.

## Limits and open points

- **Touch pass-through is unverified.** `webViewScrollInputBehavior` has no scroll input kind for iOS or macOS (`ScrollInputKind` only has watchOS and visionOS members), so the island uses `.scrollDisabled(true)` plus `overflow: hidden`. Whether a drag on the island scrolls the parent `ScrollView` on a real iPhone is not tested.
- **Not exercised:** full screen, a tap on the Docs link in a running app (a test clicks it programmatically: a synthetic `click()` counts as a link activation), a recycled island in a `LazyVStack` (the demo uses a plain `VStack` so all islands are alive; the height cache exists for the lazy case but is untested), Dynamic Type, VoiceOver inside the page.
- **One WebContent process per island.** Ten islands are ten processes; plan the artifact count per conversation (or recycle off-screen islands) before rendering a long chat's worth.
- **First paint is late.** A placeholder or cached height holds the layout; the first measure arrives after the page's first load (a cold simulator took seconds under load; not measured on a phone). A page taller than the cache grows the row when it lands.
- **A `WebPage` needs a hosting view to load on iOS.** Unhosted in a test process it never gets ready; in the app, attached to a `WebView`, it does (screenshots).
- `WebPage` has no `takeSnapshot`, no new-window (`target=_blank`) hook (the navigation decider sees it with no target frame and treats it as a main-frame link, so it opens externally; not exercised on a device) and no SwiftUI-native message API: the bridge is `WKUserContentController`.
- The default external opener is SwiftUI's `openURL` environment, not `UIApplication.shared.open`.
- A page still has no way to ask Swift for anything but `height` / `ready`; the tap-through of a link is the only outbound action.

## Tests

`ArtifactNavigationPolicyTests` (the decision matrix, including http(s) never loading inside the island), `ArtifactThemeTests`, and `ArtifactIslandTests` (a real `WebPage`: render, height up and down, `network: blocked`,
a script navigation to https leaves the page on the island scheme and opens nothing, a programmatic link click opens exactly once, an inline document loads and its `<script>` does not run, the dark scheme changes `--iris-bg`).
The `WebPage` tests run on the macOS host (`swift test`) only: in the iOS simulator's test process, with no view or window hosting the page, the WebContent process never became ready (every one of them timed out in the hosted `snapshots` job, 180 s each). The policy matrix, the theme, the scheme handler and the height cache run on both. On iOS the island is proven by the `proof-apple` screenshots, which host it in the real app, not by a test.

## Evidence

`docs/research/2026-11-webview-island/`: `ios-light.png`, `ios-dark.png` (simulator, the island between two chat bubbles at 283 pt), `mac-light.png`, `mac-dark.png` (282 pt, web content via `takeSnapshot`), `mac-memory.txt`, `ios-sim-memory.txt`.
Reproduce: `make proof-apple` (the iOS screenshots use `-IrisArtifactSpike`, the memory `-IrisArtifactIslands <n>`; the Mac run writes `artifact-island*.png` and `artifact-memory.txt`).
