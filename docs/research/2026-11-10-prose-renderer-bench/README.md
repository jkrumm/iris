# Prose renderer bench

A standalone SwiftPM package that times two markdown renderers on a streamed assistant reply, to pick the one for the Iris reply view. It is not part of any Makefile or CI target. A third candidate (Textual) is measured separately, inside `apple/Packages/IrisUI`, with the same fixture.

- `Sources/BenchCore/ProseFixture.swift` is a ~16 000 character reply (headings, nested lists, a GFM table, three code blocks, a quote, inline and block LaTeX, two prices that are not math) and `snapshots(step: 20)`, its growing prefixes. It is Foundation only; copy it verbatim into another package (drop the `public`).
- `BenchSSM` drives microsoft/SwiftStreamingMarkdown 0.7.0, `BenchMV` drives Lakr233/MarkdownView 4.8.5.

Each executable feeds every snapshot in order, lays out at 390 pt width and 16 pt body size on macOS, and times each update with `ContinuousClock` on the main thread. The first 10 updates are warm-up; it runs 3 passes and prints the median pass (mean, p50, p95, p99, max, total).

## Run

From the repo root, one build at a time (the machine is shared):

```sh
P=docs/research/2026-11-10-prose-renderer-bench
nice -n 10 scripts/apple-slot swift build --package-path $P --product BenchMV --jobs 2 -c release
nice -n 10 scripts/apple-slot swift build --package-path $P --product BenchSSM --jobs 2 -c release
nice -n 10 scripts/apple-slot $P/.build/release/BenchMV
nice -n 10 scripts/apple-slot $P/.build/release/BenchSSM
```

SwiftStreamingMarkdown is pinned by the revision of its `0.7.0` tag: SwiftPM refuses a version requirement on it, because the package itself depends on `highlightswift` and `iosMath` by revision. Anything that consumes it as a SwiftPM dependency from a Swift package (not from an Xcode project) hits the same error.

See the report of the run that produced the numbers for what each timing includes.
