import AppKit
import IrisUI
import SwiftUI

/// Settings → Connection in the panel: the server URL and device token, saved like on the iPhone (token in the Keychain).
struct MacSettingsView: View {
  @Bindable var model: ConnectionModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      DetailSectionLabel(String(localized: "Connection", comment: "Settings section"))
      TextField(
        String(localized: "Server URL", comment: "Settings connection field"), text: $model.urlText,
        prompt: Text(verbatim: "https://iris.example.com")
      )
      .textContentType(.URL)
      .autocorrectionDisabled()
      .accessibilityIdentifier("mac.settings.url")
      SecureField(String(localized: "Device token", comment: "Settings connection field"), text: $model.tokenText)
        .autocorrectionDisabled()
        .accessibilityIdentifier("mac.settings.token")
      if let failure = model.failure {
        Text(verbatim: message(for: failure))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Status.bad)
          .accessibilityIdentifier("mac.settings.error")
      }
      HStack {
        Button(String(localized: "Save", comment: "Saves the server URL and device token")) { model.save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSave)
          .accessibilityIdentifier("mac.settings.save")
        Spacer()
        Button(String(localized: "Quit Iris", comment: "Quits the menu-bar app")) {
          NSApplication.shared.terminate(nil)
        }
        .accessibilityIdentifier("mac.settings.quit")
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(Theme.Spacing.lg)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityIdentifier("mac.settings")
  }

  private func message(for failure: ConnectionModel.Failure) -> String {
    switch failure {
    case .invalid:
      String(localized: "Enter an https address and a token.", comment: "Settings connection error")
    case .insecure:
      String(
        localized: "Use an https address. Plain http is only allowed for localhost.",
        comment: "Settings connection error: the token would travel unencrypted")
    case .notStored:
      String(localized: "Could not store the token in the Keychain.", comment: "Settings connection error")
    }
  }
}
