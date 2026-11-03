import AppKit
import IrisUI
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// The Settings scene (⌘,): a native tabbed window with grouped forms. Connection (server URL, device token, test and save),
/// Recording (the global key) and General (launch at login, quit).
struct MacSettingsView: View {
  @Bindable var root: MacCompositionRoot

  var body: some View {
    TabView(selection: $root.settingsTab) {
      Tab(String(localized: "Connection", comment: "Settings tab"), systemImage: "network", value: .connection) {
        MacConnectionForm(root: root, model: root.connectionForm, tester: root.connectionTest)
      }
      Tab(String(localized: "Recording", comment: "Settings tab"), systemImage: "mic", value: .recording) {
        MacRecordingForm(hotkey: root.hotkey)
      }
      Tab(String(localized: "General", comment: "Settings tab"), systemImage: "gearshape", value: .general) {
        MacGeneralForm()
      }
    }
    .frame(width: Theme.Spacing.macSettingsWidth, height: Theme.Spacing.macSettingsHeight)
    .onAppear { root.noteWindow("settings", "open") }
    .onDisappear { root.noteWindow("settings", "close") }
    .accessibilityIdentifier("mac.settings")
  }
}

/// Server URL and device token, saved like on the iPhone (token in the Keychain), with the probe of the typed values.
struct MacConnectionForm: View {
  let root: MacCompositionRoot
  @Bindable var model: ConnectionModel
  let tester: ConnectionTester

  var body: some View {
    Form {
      Section {
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
      } footer: {
        if let failure = model.failure {
          Text(verbatim: MacConnectionForm.message(for: failure))
            .foregroundStyle(Theme.Status.bad)
            .accessibilityIdentifier("mac.settings.error")
        }
      }
      Section {
        LabeledContent(String(localized: "Status", comment: "Settings: the connection status row")) {
          status
        }
        .accessibilityIdentifier("mac.settings.status")
        MacTestResultLine(outcome: tester.outcome)
      }
      Section {
        HStack {
          Spacer()
          Button(String(localized: "Test connection", comment: "Probes the typed server URL and token without saving"))
          {
            tester.test(urlText: model.urlText, tokenText: model.tokenText)
          }
          .disabled(!model.canSave || tester.outcome == .testing)
          .accessibilityIdentifier("mac.settings.test")
          Button(String(localized: "Save", comment: "Saves the server URL and device token")) {
            model.save()
            guard model.failure == nil else { return }
            tester.test(urlText: model.urlText, tokenText: model.tokenText, saved: true)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSave)
          .accessibilityIdentifier("mac.settings.save")
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: model.urlText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
    .onChange(of: model.tokenText) { tester.fieldsChanged(urlText: model.urlText, tokenText: model.tokenText) }
  }

  private var status: some View {
    let status = MacConnectionStatus(isConfigured: root.isConfigured, link: root.history.link)
    return HStack(spacing: Theme.Spacing.snug) {
      Circle().fill(status.tone.color).frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
        .accessibilityHidden(true)
      Text(verbatim: status.title)
    }
    .help(status.hint ?? "")
  }

  static func message(for failure: ConnectionModel.Failure) -> String {
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

/// What the last probe, or the save that ran one, found: a dot and a sentence. Nothing before the first probe.
struct MacTestResultLine: View {
  let outcome: ConnectionTester.Outcome?

  var body: some View {
    if let outcome {
      let line = Self.line(for: outcome)
      HStack(spacing: Theme.Spacing.snug) {
        if outcome == .testing {
          ProgressView().controlSize(.small)
        } else {
          Circle().fill(line.color).frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
            .accessibilityHidden(true)
        }
        Text(verbatim: line.text).foregroundStyle(line.color)
      }
      .accessibilityIdentifier("mac.settings.test-result")
    }
  }

  static func line(for outcome: ConnectionTester.Outcome) -> (text: String, color: Color) {
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
}

/// The global key that starts and stops a take, recorded by the user (default Control-Option-M). The system microphone is the Mac's
/// own choice (System Settings → Sound); a take's mic rule lives in the recording panel, so there is nothing more to set here.
struct MacRecordingForm: View {
  let hotkey: any TakeHotkey
  /// Re-read after the user records another key: a combination another app holds is refused by the system.
  @State private var hotkeyRegistered: Bool

  init(hotkey: any TakeHotkey) {
    self.hotkey = hotkey
    _hotkeyRegistered = State(initialValue: hotkey.isRegistered)
  }

  var body: some View {
    Form {
      Section {
        LabeledContent(String(localized: "Start / stop key", comment: "Settings: the global recording key")) {
          KeyboardShortcuts.Recorder(for: .toggleTake) { _ in hotkeyRegistered = hotkey.isRegistered }
            .accessibilityIdentifier("mac.settings.hotkey")
        }
      } footer: {
        if !hotkeyRegistered {
          Text(
            "This key is not active. Another app may use it; record a different one.",
            comment: "Settings: the recording key is cleared or taken"
          )
          .foregroundStyle(Theme.Status.warn)
          .accessibilityIdentifier("mac.settings.hotkey-warning")
        } else {
          Text("Press it anywhere to start and stop a voice memo.", comment: "Settings: what the recording key does")
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Launch at login (`SMAppService.mainApp`) and Quit.
struct MacGeneralForm: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var failed = false

  var body: some View {
    Form {
      Section {
        Toggle(String(localized: "Launch Iris at login", comment: "Settings toggle"), isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
          .accessibilityIdentifier("mac.settings.login")
      } footer: {
        if failed {
          Text("Could not change the login item.", comment: "Settings: the login item could not be set")
            .foregroundStyle(Theme.Status.bad)
        }
      }
      Section {
        HStack {
          Spacer()
          Button(String(localized: "Quit Iris", comment: "Quits the menu-bar app")) {
            NSApplication.shared.terminate(nil)
          }
          .accessibilityIdentifier("mac.settings.quit")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func setLaunchAtLogin(_ wanted: Bool) {
    // The revert after a failure changes the toggle again: nothing to do when it already matches the system.
    guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
    failed = false
    do {
      if wanted {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      failed = true
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}
