import IrisUI
import SwiftUI

/// The server URL and device token fields of Settings' connection section, with Save.
struct ConnectionForm: View {
  @Bindable var model: ConnectionModel

  var body: some View {
    TextField(
      String(localized: "Server URL", comment: "Settings connection field"), text: $model.urlText,
      prompt: Text(verbatim: "https://iris.example.com")
    )
    .keyboardType(.URL)
    .textContentType(.URL)
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .accessibilityIdentifier("settings.connection.url")

    SecureField(String(localized: "Device token", comment: "Settings connection field"), text: $model.tokenText)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .accessibilityIdentifier("settings.connection.token")

    if let failure = model.failure {
      Text(verbatim: message(for: failure))
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier("settings.connection.error")
    }

    Button(String(localized: "Save", comment: "Saves the server URL and device token")) { model.save() }
      .disabled(!model.canSave)
      .accessibilityIdentifier("settings.connection.save")
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
