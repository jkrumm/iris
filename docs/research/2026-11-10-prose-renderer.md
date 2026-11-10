# Prose renderer: stay on Textual, chunk and buffer the stream (Issue 643)

Measured 2026-11-10 on the Mac mini, release builds, macOS host (no simulator). Versions and APIs were read from each repository at its tag, not from memory.

## Choice

Textual 0.5.0 stays. Streaming runs through three additions in `IrisUI`: the live tail is cut into chunks so only the last one is parsed again, its unfinished markup is stabilized, and updates are published through an 80 ms / newline buffer.

It does not hold 60 fps on the slowest updates. The median update costs 11 ms, the p95 63 ms, and the stream's end costs one 270 ms remount. A publish every 80 ms keeps the main thread from saturating (the p95 fits inside the buffer interval), but a long reply will not scroll smoothly through the heavy updates. Follow-ups, in order of expected gain: split long lists at item boundaries, so the live chunk stays small; parse off the main actor; keep the chunks after a reply has streamed.

The two alternatives are not an upgrade for this app, whatever their speed:

- **MarkdownView 4.8.5** is 8x faster (2.9 ms mean) but renders into its own AppKit/UIKit view. Our tables, Mermaid PNGs and quote and code cards cannot be injected as SwiftUI views (only `CodeBlockActionProvider`, `decorate(inlineText:)` and handlers), all heading levels share one font, and the reply look in TDD §4 would be rebuilt on its theme.
- **SwiftStreamingMarkdown 0.7.0** is as slow as Textual (24.5 ms mean, p95 57 ms), parses `$..$` not at all (`$E=mc^2$` stays literal), has no way to inject a custom block either, and SwiftPM refuses it as a version dependency (it pins `highlightswift` and `iosMath` by revision).

## Numbers

Fixture: `ProseFixture`, 15 843 characters (about 4 000 tokens), 793 snapshots of 20 characters; headings, nested lists, a 5 x 8 table, three code blocks, a quote, inline and block LaTeX, two prices that are not math. 390 pt wide, 16 pt body. First 10 updates dropped. Times in ms per timed update, set the content, lay out, read the fitting size, one run-loop turn.

| Renderer | Updates | Mean | p50 | p95 | p99 | Max | Total |
|-|-|-|-|-|-|-|-|
| MarkdownView 4.8.5, `setContentImmediately` + `boundingSize` | 783 | 2.90 | 2.55 | 5.95 | 6.93 | 8.98 | 2270 |
| SwiftStreamingMarkdown 0.7.0, one `rootView` swap per snapshot | 783 | 24.47 | 21.01 | 56.97 | 65.21 | 83.58 | 19161 |
| Textual A: whole string, unbuffered (every 2nd snapshot) | 387 | 28.39 | 26.19 | 65.11 | 78.69 | 145.71 | 10985 |
| Textual B: whole string behind the buffer | 560 | 23.23 | 16.40 | 58.74 | 87.75 | 91.32 | 13008 |
| Textual C: chunks + tail + buffer (the shipped path) | 560 | 22.38 | 11.39 | 62.89 | 76.94 | 91.12 | 12532 |

B and C: 570 publishes out of 793 arrivals, snapshots 50 ms apart (about 100 tokens/s). Stream end of C (the final non-streaming update, all 42 blocks remount): 269.6 ms, B: 20.6 ms. Final heights of A, B and C are equal (9547 pt).

What the rows are, and are not:

- The competitors ran in a separate package (`docs/research/2026-11-10-prose-renderer-bench/`, three median passes) under a machine load of about 30. Textual ran in `apple/Packages/IrisUI` (`ProseBenchmarkTests`, one pass) under load 6 to 10. Absolute values are noisy; only the 8x gap to MarkdownView is far outside it.
- MarkdownView lays out synchronously in CoreText. SwiftStreamingMarkdown awaits an async parse, and its code highlighting settles in later tasks, not measured. No window was on screen for any row, so drawing is not in the numbers.
- C's gain is the median (11 ms against 26 ms): committed chunks keep their strings, so Textual does not parse them again. The tail (p95 and up) is unchanged because one chunk can be large (a nested list is never cut) and the layout pass of the whole stack dominates.

## Facts per library

| | Textual 0.5.0 | MarkdownView 4.8.5 | SwiftStreamingMarkdown 0.7.0 |
|-|-|-|-|
| License | MIT | MIT | MIT |
| Min OS | iOS 18, macOS 15 | iOS 16, macOS 13 | iOS 16, macOS 14 |
| Text selection | yes, per `StructuredText` (not across our chunks while streaming) | yes, native, across blocks | per paragraph; across blocks only via a modal sheet |
| Iris theme | fonts from `Theme`, code colors per token (`HighlighterTheme`), heading, quote, code and list styles | one `title` font for all heading levels; code colors per token | per-level fonts; code colors only through highlight.js CSS |
| Math | `$..$` and `$$..$$` through `swiftui-math` (`.math` extension) | SwiftMath, `$..$`, `\(..\)`, `$$..$$` | iosMath, `\(..\)`, `$$..$$`, `\[..\]` only |
| Tables | opaque to a style; ours is `MarkdownTableView` | built in, scroll, alignment | built in, scroll, alignment |
| Custom SwiftUI blocks | yes (we cut the reply ourselves) | no | no (internal switch) |
| macOS | yes | AppKit path | yes, one SwiftUI graph per update |
| Last release | 0.5.0, 2026-06-15 | 4.8.5, 2026-10-22 | 0.7.0, 2026-08-02 |

## What was built

- `MathSpans`: pandoc's rules decide what is math ("$5 and $10" is not); the LaTeX is protected from Foundation's markdown parser (backslashes doubled, `*` and `_` escaped) and `.math` is enabled only for a text block that holds a valid span.
- A copy button on every code block (`CodeBlockProxy.copyToPasteboard`).
- Tables scroll sideways with a trailing fade, honour `:--` / `:-:` / `--:`, and wrap a cell at 240 pt. The card-per-row fallback is gone.
- `MessageContentView(markdown:isStreaming:)`, `StreamBuffer`, `StreamingReplyModel`, `StreamingTail.stabilize`; chunking exists only while streaming, a finished reply is one `StructuredText` per text run as before. Chunked height equals the unchunked height within 1 pt for the fixture and nine small layouts, at 16 pt and 13 pt.

## Open

- Real on-screen scroll smoothness of a streaming reply is not measured; the numbers are layout cost on the host.
- The 270 ms remount at stream end is one visible hitch on a long reply. The way out is to keep the chunks after a stream, at the price of selection across paragraphs.
- SwiftStreamingMarkdown's highlighting cost after layout is not in its row.
