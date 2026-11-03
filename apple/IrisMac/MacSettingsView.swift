import AppKit
import IrisUI
import KeyboardShortcuts
import SwiftUI

/// Settings → Connection in the panel: the server URL and device token, saved like on the iPhone (token in the Keychain).
struct MacSettingsView: View {
  let root: MacCompositionRoot
  @Bindable var model: ConnectionModel
  let hotkey: any TakeHotkey
  /// Re-read after the user records another key: a combination another app holds is refused by the system.
  @State private var hotkeyRegistered: Bool

  init(root: MacCompositionRoot, model: ConnectionModel, hotkey: any TakeHotkey) {
    self.root = root
    self.model = model
    self.hotkey = hotkey
    _hotkeyRegistered = State(initialValue: hotkey.isRegistered)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      MacPageHeader(title: String(localized: "Settings", comment: "Panel page")) { root.goHome() }
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
      testResult
      recordingSection
      HStack {
        Button(String(localized: "Save", comment: "Saves the server URL and device token")) {
          model.save()
          guard model.failure == nil else { return }
          tester.test(urlText: model.urlText, tokenText: model.tokenText, saved: true)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .accessibilityIdentifier("mac.settings.save")
        Button(String(localized: "Test connection", comment: "Probes the typed server URL and token without saving")) {
          tester.test(urlText: model.urlText, tokenText: model.tokenText)
        }
        .disabled(!model.canSave || tester.outcome == .testing)
        .accessibilityIdentifier("mac.settings.test")
        Spacer()
        Button(String(localized: "Quit Iris", comment: "Quits the menu-bar app")) {
          NSApplication.shared.terminate(nil)
        }
        .accessibilityIdentifier("mac.settings.quit")
      }
    }
    .textFieldStyle(.roundedBorder)
    .onChange(of: model.urlText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
    .onChange(of: model.tokenText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
    .padding(Theme.Spacing.menuInset)
    .frame(height: Theme.Spacing.menuPageHeight, alignment: .top)
    .accessibilityIdentifier("mac.settings")
  }

  private var tester: ConnectionTester { root.connectionTest }

  /// What the last probe, or the save that ran one, found.
  @ViewBuilder private var testResult: some View {
    if let outcome = tester.outcome {
      let line = Self.line(for: outcome)
      HStack(spacing: Theme.Spacing.snug) {
        if outcome == .testing {
          ProgressView().controlSize(.small)
        } else {
          Circle().fill(line.color).frame(width: 8, height: 8).accessibilityHidden(true)
        }
        Text(verbatim: line.text).themeFont(.footnote).foregroundStyle(line.color)
      }
      .accessibilityIdentifier("mac.settings.test-result")
    }
  }

  private static func line(for outcome: ConnectionTester.Outcome) -> (text: String, color: Color) {
    switch outcome {
    case .testing:
      (String(localized: "Testing…", comment: "Connection test in progress"), Theme.Ink.muted)
    case .connected:
      (String(localized: "Connected", comment: "Server connection"), Theme.Status.good)
    case .savedConnected:
      (String(localized: "Saved — connected", comment: "Connection saved and the probe passed"), Theme.Status.good)
    case .rejected:
      (String(localized: "Token rejected", comment: "Server connection"), Theme.Status.bad)
    case .unreachable:
      (
        String(
          localized: "Server not reachable — is Tailscale on?", comment: "Connection hint: the server cannot be reached"
        ),
        Theme.Status.bad
      )
    case .serverError:
      (
        String(
          localized: "Server answered with an error", comment: "Connection test: the server answered, not healthy"),
        Theme.Ink.muted
      )
    case .invalid:
      (String(localized: "Enter an https address and a token.", comment: "Settings connection error"), Theme.Status.bad)
    }
  }

  /// The global key that starts and stops a take, recorded by the user (default Control-Option-M).
  private var recordingSection: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      DetailSectionLabel(String(localized: "Recording", comment: "Settings section"))
      HStack {
        Text(String(localized: "Start / stop key", comment: "Settings: the global recording key"))
          .themeFont(.footnote)
        Spacer()
        KeyboardShortcuts.Recorder(for: .toggleTake) { _ in hotkeyRegistered = hotkey.isRegistered }
          .accessibilityIdentifier("mac.settings.hotkey")
      }
      if !hotkeyRegistered {
        Text(
          String(
            localized: "This key is not active. Another app may use it; record a different one.",
            comment: "Settings: the recording key is cleared or taken")
        )
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.warn)
        .accessibilityIdentifier("mac.settings.hotkey-warning")
      }
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
