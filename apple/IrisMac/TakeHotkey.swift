import AppKit
import Foundation
import KeyboardShortcuts

/// The global key that starts and stops a take, behind a port so the panel model tests without registering a hotkey.
/// Production: `KeyboardShortcutsHotkey`. Fake: `FakeTakeHotkey`.
@MainActor
protocol TakeHotkey {
  /// One value per press of the key, in any app. One consumer.
  var presses: AsyncStream<Void> { get }
  /// The key is registered with the system. False when the user cleared it or another app holds the combination (Carbon
  /// refuses a duplicate silently), so Settings can say so.
  var isRegistered: Bool { get }
}

extension KeyboardShortcuts.Name {
  /// Control-Option-M. Control-Option-Space is the system's "next input source", and no default is Fn, double-Fn or a
  /// Cmd-Shift-Space style key, which are the owner's dictation keys (docs/research/2026-10-31-mac-hotkey.md).
  static let toggleTake = Self("toggleTake", initial: KeyboardShortcutsHotkey.defaultShortcut)
}

/// `KeyboardShortcuts` (Carbon `RegisterEventHotKey`): no Accessibility or Input Monitoring prompt, works in the sandbox. The
/// shortcut the user records in Settings is stored by the package in `UserDefaults`.
@MainActor
struct KeyboardShortcutsHotkey: TakeHotkey {
  /// Control-Option-M.
  static let defaultShortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.control, .option])

  let name: KeyboardShortcuts.Name

  init(name: KeyboardShortcuts.Name = .toggleTake) {
    self.name = name
  }

  var presses: AsyncStream<Void> {
    let name = name
    return AsyncStream { continuation in
      // Owned by the stream; ending the sequence unregisters the listener.
      let listening = Task { @MainActor in
        for await _ in KeyboardShortcuts.events(.keyDown, for: name) { continuation.yield() }
        continuation.finish()
      }
      continuation.onTermination = { _ in listening.cancel() }
    }
  }

  var isRegistered: Bool { KeyboardShortcuts.isEnabled(for: name) }
}

/// A key the test presses.
@MainActor
final class FakeTakeHotkey: TakeHotkey {
  let presses: AsyncStream<Void>
  private let sink: AsyncStream<Void>.Continuation
  var isRegistered = true

  init() {
    (presses, sink) = AsyncStream.makeStream(of: Void.self)
  }

  func press() { sink.yield() }
}
