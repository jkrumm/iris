import IrisUI
import SwiftUI

/// The server URL and device token fields of Settings' connection section, with Save.
struct ConnectionForm: View {
  @Bindable var model: ConnectionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField(
        String(localized: "Server URL", comment: "Settings connection field"), text: $model.urlText,
        prompt: Text(verbatim: "https://iris.example.com")
      )
      .keyboardType(.URL)
      .textContentType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .themeFont(.subheadline)
      .settingsRow()
      .accessibilityIdentifier("settings.connection.url")

      Divider().overlay(Theme.divider)
      SecureField(String(localized: "Device token", comment: "Settings connection field"), text: $model.tokenText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .themeFont(.subheadline)
        .settingsRow()
        .accessibilityIdentifier("settings.connection.token")

      if let failure = model.failure {
        Divider().overlay(Theme.divider)
        Text(verbatim: message(for: failure))
          .themeFont(.footnote)
          .foregroundStyle(Theme.Status.bad)
          .settingsRow()
          .accessibilityIdentifier("settings.connection.error")
      }

      Divider().overlay(Theme.divider)
      Button(String(localized: "Save", comment: "Saves the server URL and device token")) { model.save() }
        .themeFont(.subheadline, weight: .semibold)
        .disabled(!model.canSave)
        .settingsRow()
        .accessibilityIdentifier("settings.connection.save")
    }
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
