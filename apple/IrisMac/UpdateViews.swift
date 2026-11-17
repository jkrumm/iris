import IrisUI
import SwiftUI

/// "Check for Updates…" in Settings > General (the popover uses a `MacMenuLine`, id `mac.menu.update`, bound to the same
/// `Updater`). Disabled while a check or an install runs (`canCheckForUpdates`); absent under `-IrisFakeData`, where the
/// root has no updater.
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

/// Settings > General: whether this version is current, and the install action while it is not. Sparkle's own window does the
/// install; the button re-presents the update it found.
struct UpdateStateRow: View {
  let updater: Updater

  var body: some View {
    LabeledContent(String(localized: "Updates", comment: "Settings: the update state row")) {
      switch updater.status {
      case .unknown:
        Text("Not checked yet", comment: "Settings: no update check has finished")
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityIdentifier("mac.update.state")
      case .upToDate:
        Text("Up to date", comment: "Settings: this is the newest version")
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityIdentifier("mac.update.state")
      case .available(let version, _):
        HStack {
          Text(
            "Version \(version) available",
            comment: "Settings: a newer version exists; the argument is its version number"
          )
          .foregroundStyle(Theme.Accent.tint)
          .accessibilityIdentifier("mac.update.state")
          Button(String(localized: "Install…", comment: "Settings: opens the update window to install the new version"))
          {
            updater.checkForUpdates()
          }
          .disabled(!updater.canCheckForUpdates)
          .accessibilityIdentifier("mac.update.install")
        }
      }
    }
  }
}

/// The quiet mark of an available update, in the main window's toolbar and the popover: shown only while one is available.
struct UpdateBadge: View {
  let updater: Updater

  var body: some View {
    if let version = updater.availableVersion {
      Button {
        updater.checkForUpdates()
      } label: {
        Label(
          String(
            localized: "Version \(version) available", comment: "Update badge; the argument is the version number"),
          systemImage: "arrow.down.circle")
      }
      .labelStyle(.iconOnly)
      .foregroundStyle(Theme.Accent.tint)
      .help(
        String(localized: "Version \(version) available", comment: "Update badge; the argument is the version number")
      )
      .disabled(!updater.canCheckForUpdates)
      .accessibilityIdentifier("mac.update.badge")
    }
  }
}
