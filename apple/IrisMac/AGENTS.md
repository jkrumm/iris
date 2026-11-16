# IrisMac (menu-bar app, windows, global hotkey)

Design is `docs/TDD.md` §5. The Mac app reuses the iPhone's packages and composes them in `MacCompositionRoot`. Screens, scenes, keyboard behaviour, snapshot names and release history: `docs/mac-app.md`; read it before changing a window, the popover, the composer or the activation policy. Signing, notarization and Sparkle: `docs/release-and-ops.md` and skill `apple-signing`.

- `-IrisFakeData` runs the whole app on fakes (no microphone, no prompt, no hotkey registration, no updater); an unsigned build (CI, `make check-apple`) never records.
- The app is not sandboxed (Hardened Runtime `audio-input` only; no App Group, no network entitlement) and updates itself with Sparkle.
- macOS has no `AVAudioSession`: `MacAudioSessionController` is a no-op and `DirectoryRouteManager` over Core Audio is the route manager. Picking a microphone sets the system default input and the take's end restores it; the original is persisted first so a kill mid-take is undone at the next launch.
- The global key is `KeyboardShortcuts` on Carbon (no permission prompt, no `CGEventTap`), default Control-Option-M; Control-Option-Space is the system's input-source switch. The key continues the open conversation's Hermes session, else starts a new memo.
- The macOS `List` clips a row to 24 pt unless both `.environment(\.defaultMinListRowHeight, …)` and the row's `.frame(minHeight: …)` carry `Theme.Spacing.macRowMinHeight`.
- LSUIElement apps need `NSApp.activate()` before a window opens. `MacActivationPolicy` makes the app `.regular` while a titled window that can be main is visible and `.accessory` after the last closes; panels never count.
- The desktop uses `macFont(.caption|.body|.lead|.title)` (11, 13, 15, 18 pt), not the iPhone's `themeFont` roles, and `mac*` / `window*` spacing roles.
- Mac device events are `MacEvents` / `DeviceLog.event` with `service.name=iris-macos`, never a bare `Logger` call, and never a transcript, reply, banner text, token, URL or device id.
- Banners never carry transcript, reply or failure reason. `MemoNotifier` announces from the open event stream only, so a memo that finished while the app was not running is not announced (known limit).
- Both the popover and the window drive one event stream (the fake client has one consumer): `StreamTappingClient.mirror` hands each event to the window. Do not open a second stream.
- Window snapshots run with `-IrisMacSnapshot <dir>` placed after `-IrisMacPanelWindow` (a flag between them stops the panel window from being created), once with `-AppleLanguages "(en)"` and once with `"(de)"`; `make proof-apple` does both. Windows with chrome are captured through `CGWindowListCreateImage` looked up with `dlsym`; `cacheDisplay` leaves the sidebar, materials and toolbar blank.
