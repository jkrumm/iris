---
description: Swift / SwiftUI coding standards for the Iris Apple targets and packages
paths: ["**/*.swift", "**/Package.swift", "**/project.yml", "**/*.xcconfig"]
---

# Swift Standards

Toolchain: Xcode 27.1, Swift 6.4, iOS/macOS 26.0 minimum. Iris invariants (capture, outbox, Live Activity limits)
live in `.claude/rules/apple.md`; this file is generic Swift.

## Language mode and concurrency

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_APPROACHABLE_CONCURRENCY = YES` in every target.
- App and extension targets: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (the spelling is verified against the 27.1
  `Swift.xcspec`; values are `nonisolated | MainActor`). Library packages stay `nonisolated` by default and mark UI types
  `@MainActor` explicitly; `IrisUI` may set `.defaultIsolation(MainActor.self)` in `Package.swift`.
- Shared mutable state lives in an `actor` or on `@MainActor`. No locks, no `DispatchQueue`, no `@unchecked Sendable`
  without a comment that names the invariant that makes it safe.
- Cross-isolation values are `Sendable` value types. Use `async let` / `TaskGroup` for structure, `AsyncStream` for events.
  A detached or unstructured `Task` needs an owner that cancels it.
- Background work that must not inherit the caller's actor is `@concurrent`; never `Task.detached` to escape the main actor.

## State and views

- `@Observable` classes (Observation framework). Never `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`.
- `@State` owns, `@Bindable` binds, `@Environment` injects. Views stay small; logic goes in an `@Observable` model that
  takes its dependencies through the initializer.
- Navigation: `NavigationStack` / `NavigationSplitView` with value-based destinations. Liquid Glass via `glassEffect(_:in:)`
  and `GlassEffectContainer`, applied last; keep few glass surfaces on screen.
- Every interactive element gets an accessibility label; support Dynamic Type; use semantic colors from `IrisUI/Theme`.

## Ports and adapters, tests

- Every external dependency (network, audio session, clock, file system, push) is a `protocol` owned by the consuming
  module, with a production adapter and an in-memory fake (`FakeCapture`, `FakeAPIClient`). Inject, don't layer.
  No mocking frameworks, no method swizzling, no singletons reached from views.
- Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite`, parameterized tests) for everything except UI tests,
  which stay XCTest/XCUITest. Test through public interfaces; `@testable import` is for tests only.
- Snapshot tests use swift-snapshot-testing with the simulator runtime pinned (see `.claude/skills/apple-dev`).

## Hygiene

- `os.Logger` with a subsystem and category per module. No `print`, no `NSLog`. Never log tokens, transcripts or URLs with
  credentials.
- No force unwraps, `try!`, `as!` or implicitly unwrapped optionals outside tests. Guard and early-return; throw typed
  errors from module boundaries.
- Format with `swift format` (config: `.swift-format` at repo root); `swift format lint --strict` must be clean.
- No third-party UI kits for glass or layout. New dependencies need a reason in the PR and a pinned version.
- Strings are `String(localized:)`; German and English ship from the start.

## Research first

Your training predates iOS 26 / 27 and macOS 26 / 27 APIs. For any API introduced after iOS 18 (`glassEffect`,
`AudioRecordingIntent`, `LiveActivityIntent`, ControlWidget, `SpeechTranscriber`, Textual, SwiftUI toolbar APIs): run
`/research` or read Apple's documentation first, and compile it before claiming it exists. Never invent a signature.

## Skills to load

Read the matching vendored skill before writing or reviewing that kind of code (`.claude/skills/VENDORED.md`):

| Code | Skill |
|-|-|
| SwiftUI views, navigation, layout, design | `swiftui-pro` |
| actors, `async`/`await`, `Sendable`, isolation errors | `swift-concurrency-pro` |
| tests | `swift-testing-pro` |
| SwiftData (not used yet) | `swiftdata-pro` |
| building, simulator, devices, signing | `apple-dev` |
