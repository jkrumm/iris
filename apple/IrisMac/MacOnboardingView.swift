import IrisUI
import SwiftUI

/// The first-launch window while nothing is saved: what Iris is, the server URL and device token, Test connection. Continue is
/// available once the probe has passed; it saves the connection, closes the window and opens the main window. Also reached from the
/// popover's connect prompt.
struct MacOnboardingView: View {
  let root: MacCompositionRoot
  @Bindable var model: ConnectionModel
  let tester: ConnectionTester
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macOnboardingGap) {
      VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
        Image(systemName: "waveform")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(Theme.Accent.tint)
          .accessibilityHidden(true)
        Text("Welcome to Iris", comment: "Onboarding title")
          .macFont(.title, weight: .semibold)
        Text(
          "Record a voice memo with one key. Iris transcribes it, sends it where it belongs and tells you when it is done.",
          comment: "Onboarding: what the app does"
        )
        .macFont(.body)
        .foregroundStyle(Theme.Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Form {
        TextField(
          String(localized: "Server URL", comment: "Settings connection field"), text: $model.urlText,
          prompt: Text(verbatim: "https://iris.example.com")
        )
        .textContentType(.URL)
        .autocorrectionDisabled()
        .accessibilityIdentifier("mac.onboarding.url")
        SecureField(String(localized: "Device token", comment: "Settings connection field"), text: $model.tokenText)
          .autocorrectionDisabled()
          .onSubmit(test)
          .accessibilityIdentifier("mac.onboarding.token")
      }
      .formStyle(.columns)
      HStack(spacing: Theme.Spacing.sm) {
        MacTestResultLine(outcome: tester.outcome)
          .macFont(.body)
        if let failure = model.failure {
          Text(verbatim: MacConnectionForm.message(for: failure)).foregroundStyle(Theme.Status.bad)
            .macFont(.body)
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: Theme.Spacing.xl)
      Spacer(minLength: 0)
      HStack {
        Button(String(localized: "Not now", comment: "Onboarding: closes without connecting")) {
          dismissWindow(id: MacWindowID.onboarding)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("mac.onboarding.skip")
        Spacer()
        Button(
          String(localized: "Test connection", comment: "Probes the typed server URL and token without saving"),
          action: test
        )
        .disabled(!model.canSave || tester.outcome == .testing)
        .accessibilityIdentifier("mac.onboarding.test")
        Button(
          String(localized: "Continue", comment: "Onboarding: saves the connection and opens Iris"), action: finish
        )
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canContinue)
        .accessibilityIdentifier("mac.onboarding.continue")
      }
    }
    .padding(Theme.Spacing.macOnboardingInset)
    .frame(width: Theme.Spacing.macOnboardingWidth, height: Theme.Spacing.macOnboardingHeight)
    .background(Theme.Surface.background)
    .onChange(of: model.urlText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
    .onChange(of: model.tokenText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
    .onAppear { root.noteWindow("onboarding", "open") }
    .onDisappear { root.noteWindow("onboarding", "close") }
    .accessibilityIdentifier("mac.onboarding")
  }

  /// The connection can be saved once the probe of these very values has passed.
  private var canContinue: Bool { tester.outcome == .connected }

  private func test() {
    guard model.canSave else { return }
    tester.test(urlText: model.urlText, tokenText: model.tokenText)
  }

  private func finish() {
    guard canContinue else { return }
    model.save()
    guard model.failure == nil else { return }
    dismissWindow(id: MacWindowID.onboarding)
    root.showMainWindow(source: "onboarding")
  }
}
