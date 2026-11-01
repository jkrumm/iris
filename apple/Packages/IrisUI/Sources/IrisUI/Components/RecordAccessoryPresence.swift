import Observation
import SwiftUI

/// Which screens carry their own bottom actions, so the app can take the record control (the tab bar's bottom accessory) off the
/// screen while one is shown. Hiding the tab bar on a pushed screen does not hide the accessory, and the accessory then sits
/// over the screen's action bar and swallows its taps. The app creates one and injects it above the `TabView`; a screen
/// registers through ``View/hidesRecordAccessory()``. Counted, not a flag: a push registers the new screen before the old one
/// leaves.
@MainActor
@Observable
public final class RecordAccessoryPresence {
  public private(set) var holders = 0

  public var isHidden: Bool { holders > 0 }

  public init() {}

  func enter() {
    holders += 1
  }

  func leave() {
    holders = max(0, holders - 1)
  }
}

private struct HidesRecordAccessory: ViewModifier {
  @Environment(RecordAccessoryPresence.self) private var presence: RecordAccessoryPresence?
  @State private var isRegistered = false

  func body(content: Content) -> some View {
    content
      .onAppear {
        guard !isRegistered else { return }
        isRegistered = true
        presence?.enter()
      }
      .onDisappear {
        guard isRegistered else { return }
        isRegistered = false
        presence?.leave()
      }
  }
}

extension View {
  /// While this view is on screen the record control is off it (no effect without a ``RecordAccessoryPresence`` in the environment).
  public func hidesRecordAccessory() -> some View {
    modifier(HidesRecordAccessory())
  }
}
