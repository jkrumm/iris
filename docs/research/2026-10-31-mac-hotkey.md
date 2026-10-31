# Mac global hotkey: KeyboardShortcuts or a CGEventTap

Run `01a1904e-4510-7757-8072-668b08e9116f` (`agw research --depth standard`), 2026-10-31, status `ok`. Two of its citations were dropped as
unretrieved (issues #241 and #244 pages); the claims they carried are marked as leads below. Decisions live in `docs/TDD.md` §5.

## Decision

**`KeyboardShortcuts` 3.1.0, Carbon path, App Sandbox and `LSUIElement` kept. No `CGEventTap` fallback.**
Default shortcut **Control-Option-M** (M for memo), user-configurable in Mac Settings through `KeyboardShortcuts.Recorder`.

**Control-Option-Space is not free** (the brief's example): Apple binds it to "select the next input source in the Input menu"
([support.apple.com](https://support.apple.com/en-gb/guide/mac-help/mchlp1406/mac)), live as soon as a second input source (German + US)
is configured, and the recorder's `CopySymbolicHotKeys` check warns on it. Control-Option-letter has no default system binding (high
confidence it is not a system key; VoiceOver uses Control-Option as its modifier, only while VoiceOver runs). It is also distinct from
the owner's dictation keys (Fn, double Fn, Cmd-Shift-Space style), which the default never touches.

## Why Carbon

| Claim | Confidence | Source |
|-|-|-|
| Registers through Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` (one `InstallEventHandler`, `kEventHotKeyPressed` / `Released`) | high | [HotKey.swift@3.1.0](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/3.1.0/Sources/KeyboardShortcuts/HotKey.swift) |
| No Accessibility, no Input Monitoring, no TCC dialog; "fully sandboxed and Mac App Store compatible"; no entitlement | high | [readme@3.1.0](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/3.1.0/readme.md) |
| Independent sandboxed `LSUIElement` MAS app saw no prompt with Carbon hotkeys | medium | [dev.to report](https://dev.to/eduardo_revillavaquero_0/i-shipped-a-clipboard-manager-inside-the-macos-app-store-sandbox-heres-what-works-and-what-5a30) |
| 3.1.0 released 2026-09-11, macOS 27 compatibility, recorder fixes; SwiftPM only; macOS 10.15+ | high | [releases](https://github.com/sindresorhus/KeyboardShortcuts/releases), [Package.swift](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/3.1.0/Package.swift) |
| `swift-tools-version:6.2`, `defaultIsolation(MainActor.self)`: compiles in Swift 6 mode, needs Xcode 26+ (we run 27.1) | high | Package.swift above |
| `Shortcut`, `Name`, `EventType`, `ConflictPolicy` are `Sendable`; handlers run on the main actor; `onKeyDown/onKeyUp` are to be deprecated, `events(for:)` (`AsyncStream<EventType>`) is the new API | high | [KeyboardShortcuts.swift@3.1.0](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/3.1.0/Sources/KeyboardShortcuts/KeyboardShortcuts.swift) |
| `Recorder` is a SwiftUI view (`Recorder(for: Name)` stores in `UserDefaults`); blocks unmodified and Shift-only keys, blocks main-menu clashes, warns ("Use Anyway") on enabled system hotkeys | high | [Recorder.swift](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/Recorder.swift), [ConflictPolicy.swift](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/3.1.0/Sources/KeyboardShortcuts/ConflictPolicy.swift) |

## macOS 26 caveats (and what we do about them)

- The recorder was broken on macOS 26/27 before 3.1.0 (issue #241: local-monitor token no longer retained). 3.1.0's source holds it
  strongly. Lead, issue page not retrieved; the source change is high confidence. **Pin `from: "3.1.0"`.**
- Open issues #243 (fires twice) and #244 (missed key-down) occur only while one of our own `NSMenu`s is tracking. Leads (pages not
  retrieved). Our status item is a `.window`-style `MenuBarExtra`, not an `NSMenu`, so the Carbon path stays in charge; the hands-on row
  presses the hotkey with the popover open.
- Bare F13-F20 are rejected by Carbon on 26.6.2 (third-party probe, medium): the recorder would save a shortcut that never
  fires. The default is a modifier chord, and Settings shows a warning when `KeyboardShortcuts.isEnabled(for:)` is false after a
  change (cleared, or held by another app), which is the one signal the package gives for a silent registration failure.
- Another app holding the combination makes Carbon registration fail silently; the recorder cannot see it (source-read, no
  runtime test; the registered default is checked by the hands-on row).
- Media keys, Caps Lock and Fn are unsupported. Not needed.

## CGEventTap fallback: why not

| Tap | Permission | Sandbox | Cost |
|-|-|-|-|
| `.listenOnly` | Input Monitoring (`kTCCServiceListenEvent`) | compatible (Apple DTS recommends it for sandboxed apps) | a "monitor all keystrokes" consent, System Settings trip, relaunch, grants bound to the signature; the app may not appear in the list without `IOHIDRequestAccess()` |
| `.defaultTap` | Accessibility | not viable in a sandboxed app | a stale tap outliving a revoked grant can freeze all input until quit |

Sources: Apple DTS threads [707680](https://developer.apple.com/forums/thread/707680?answerId=802852022) and
[828052](https://developer.apple.com/forums/thread/828052) (high); tap behaviour reports (medium). A tap buys only modifier-only
triggers, media keys and consuming the key. None is wanted, so the fallback is not built. Revisit only for a modifier-alone trigger,
as a separate opt-in listen-only tap.

## Not verified

- Whether `CopySymbolicHotKeys` flags Control-Option-Space on a Mac with a single input source (inferred from code + docs).
- Option-only registration in a sandbox on macOS 26 (we do not offer it: it steals characters such as Option-P).
