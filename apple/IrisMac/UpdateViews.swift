import SwiftUI

/// "Check for Updates…": the one item the popover's lines and Settings > General share. Disabled while a check or an install
/// runs (`canCheckForUpdates`); absent under `-IrisFakeData`, where the root has no updater.
struct CheckForUpdatesButton: View {
  let updater: Updater

  var body: some View {
    Button(
      String(localized: "Check for Updates…", comment: "Menu item and Settings button: looks for a new version of Iris")
    ) {
      updater.checkForUpdates()
    }
    .disabled(!updater.canCheckForUpdates)
    .accessibilityIdentifier("mac.update.check")
  }
}
