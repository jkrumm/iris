import IrisCore
import IrisUI
import SwiftUI

/// The Settings tab: Diagnostics up front, the server connection, and the outbox queue.
struct SettingsView: View {
  let model: SettingsModel
  let history: HistoryModel
  let diagnostics: DiagnosticsModel
  let micRules: MicRulesModel
  let spokenReplies: SpokenReplies
  /// The editable URL and token; nil when the app runs on fakes and has no connection to edit.
  var connectionForm: ConnectionModel?

  var body: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink {
            DiagnosticsView(model: diagnostics, history: history, quarantinedFiles: model.quarantinedFiles)
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostics", comment: "Settings row")
                Text("Copy a memo id for debugging", comment: "Settings row detail")
                  .themeFont(.footnote)
                  .foregroundStyle(Theme.Ink.muted)
              }
            } icon: {
              Image(systemName: "stethoscope").foregroundStyle(Theme.Accent.tint)
            }
          }
          .accessibilityIdentifier("settings.diagnostics")
        }
        .listRowBackground(Theme.Surface.panel)

        Section {
          LabeledContent(String(localized: "Server", comment: "Settings row")) {
            connectionLabel
          }
          if let connectionForm { ConnectionForm(model: connectionForm) }
        } header: {
          Text("Connection", comment: "Settings section")
        } footer: {
          if model.connection == .notConfigured {
            Text("Enter the server URL and this device's token to connect.", comment: "Settings connection hint")
              .accessibilityIdentifier("settings.connection.hint")
          } else if let hint = connectionStatus.hint {
            Text(verbatim: hint)
              .accessibilityIdentifier("settings.server.hint")
          }
        }
        .listRowBackground(Theme.Surface.panel)

        outbox
        setAside

        playback
        RouteConfigEntry(micRules: micRules)
        microphone
      }
      .accessibilityIdentifier("settings.view")
      .takeBanner()
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .navigationTitle(String(localized: "Settings", comment: "Navigation title of the Settings tab"))
      .task { await model.load() }
      .task { await micRules.load() }
      .task { await model.observeQueue() }
      .refreshable {
        await model.load()
        await micRules.load()
      }
    }
  }

  /// Spoken replies: a finished memo is read out on its own while the app is open.
  private var playback: some View {
    @Bindable var spokenReplies = spokenReplies
    return Section {
      Toggle(isOn: $spokenReplies.isOn) {
        Label {
          Text("Spoken replies", comment: "Settings toggle")
        } icon: {
          Image(systemName: "speaker.wave.2").foregroundStyle(Theme.Accent.tint)
        }
      }
      .accessibilityIdentifier("settings.spokenReplies")
    } header: {
      Text("Playback", comment: "Settings section")
    } footer: {
      Text(
        "When on, the reply to a memo you recorded here is read out as soon as it is done, while Iris is open. Play always speaks it on demand.",
        comment: "Settings spoken replies hint")
    }
    .listRowBackground(Theme.Surface.panel)
  }

  /// The microphone rule of the audio route in use right now.
  private var microphone: some View {
    Section {
      MicRuleList(
        routeTitle: micRules.routeTitle,
        routeCaption: String(
          localized: "Recording starts with the microphone you pick for this route.",
          comment: "Settings mic rule caption"),
        choices: micRules.choices, selection: micRules.selection
      ) { uid in
        Task { await micRules.pick(uid) }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings.mic")
    } header: {
      Text("Microphone", comment: "Settings section")
    } footer: {
      Text(
        "Rules are kept on this device, one per audio route (for example the car's Bluetooth). Connect to another route to set its rule.",
        comment: "Settings mic rule hint")
    }
    .listRowBackground(Theme.Surface.panel)
  }

  private var connectionStatus: ConnectionStatusLine {
    ConnectionStatusLine(
      connection: model.connection, link: history.link, probedAt: model.probedAt, linkObservedAt: history.linkObservedAt
    )
  }

  private var connectionLabel: some View {
    let status = connectionStatus
    return HStack(spacing: Theme.Spacing.sm) {
      Circle().fill(Self.color(for: status.tone)).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(verbatim: status.title).foregroundStyle(Theme.Ink.secondary)
        .accessibilityIdentifier("settings.server.status")
    }

  }

  private static func color(for tone: ConnectionStatusLine.Tone) -> Color {
    switch tone {
    case .good: Theme.Status.good
    case .warn: Theme.Status.warn
    case .bad: Theme.Status.bad
    case .muted: Theme.Ink.muted
    }
  }

  private var outbox: some View {
    Section {
      if model.queueUnavailable {
        Label {
          Text(
            "The outbox cannot be opened, so new memos are not accepted. Iris tries again when you pull to refresh or reopen the app.",
            comment: "Outbox unavailable")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
        }
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityIdentifier("settings.outbox.unavailable")
      }
      if model.resetLeftUnopened {
        Label {
          Text(
            "The old outbox file was set aside and kept, but a new outbox could not be opened yet. Iris tries again when you pull to refresh or reopen the app.",
            comment: "Outbox reset left unopened")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
        }
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityIdentifier("settings.outbox.resetunopened")
      }
      if model.discardFailed {
        Text(
          "The outbox could not be opened, so nothing was discarded. Try again when it is available.",
          comment: "Outbox discard failed"
        )
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier("settings.outbox.discardfailed")
      }
      if model.queueUnreadable {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          Text(
            "The saved outbox cannot be read, so it is set aside. Resetting renames the file and keeps it, recordings included, and opens an empty outbox. Diagnostics can share the old file.",
            comment: "Outbox unreadable"
          )
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.secondary)
          if model.resetFailed {
            Text("The outbox could not be reset. Nothing was changed.", comment: "Outbox reset failed")
              .themeFont(.footnote)
              .foregroundStyle(Theme.Status.bad)
              .accessibilityIdentifier("settings.outbox.resetfailed")
          }
          Button(String(localized: "Reset outbox", comment: "Outbox action"), role: .destructive) {
            Task { await model.resetOutbox() }
          }
          .buttonStyle(.borderless)
          .themeFont(.footnote, weight: .medium)
          .accessibilityIdentifier("settings.outbox.reset")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.outbox.unreadable")
      }
      if model.queueSaveFailure != nil {
        Label {
          Text(
            "The queue could not be saved to this device. Recordings wait to be sent until it can, and Iris keeps trying.",
            comment: "Outbox save failed")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
        }
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityIdentifier("settings.outbox.savefailed")
      }
      if model.queue.isEmpty && !model.queueUnavailable {
        Text("Nothing waiting. Memos and chat messages that cannot be sent yet queue here.", comment: "Outbox empty")
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityIdentifier("settings.outbox.empty")
      } else {
        ForEach(model.queue) { item in
          row(for: item)
        }
      }
    } header: {
      Text("Outbox", comment: "Settings section")
    }
    .listRowBackground(Theme.Surface.panel)
    .animation(.snappy, value: model.queue)
  }

  /// Files the app set aside instead of deleting: shown with their count and size, shared on request, never removed here.
  @ViewBuilder
  private var setAside: some View {
    let summary = model.setAside
    if !summary.isEmpty {
      Section {
        LabeledContent(String(localized: "Kept on this device", comment: "Settings set-aside row")) {
          Text(
            "\(summary.count) files · \(SetAsideSummary.size(summary.byteCount))",
            comment: "Settings set-aside count and size"
          )
          .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.setaside")
        if summary.exceedsBound {
          Label {
            Text(
              "That is a lot. Iris never deletes them on its own; share the list to have them looked at.",
              comment: "Settings set-aside bound exceeded")
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
          }
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.secondary)
          .accessibilityIdentifier("settings.setaside.large")
        }
        ShareLink(
          item: summary.report,
          preview: SharePreview(String(localized: "Set-aside files", comment: "Share sheet title"))
        ) {
          Label(
            String(localized: "Share or copy the list", comment: "Settings set-aside action"), systemImage: "doc.on.doc"
          )
        }
        .accessibilityIdentifier("settings.setaside.share")
      } header: {
        Text("Set-aside files", comment: "Settings section")
      } footer: {
        Text(
          "Outbox files that could not be read and recordings no queue entry owned. They are kept, never deleted on their own.",
          comment: "Settings set-aside footer")
      }
      .listRowBackground(Theme.Surface.panel)
    }
  }

  private func row(for item: QueuedItem) -> some View {
    let canRetry: Bool
    if case .failed = item.state { canRetry = true } else { canRetry = false }
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      OutboxItemRow(
        systemImage: item.kind.systemImage, title: item.title, detail: detail(of: item), status: item.state.status,
        statusText: statusText(of: item.state)
      )
      .accessibilityIdentifier("settings.outbox.row")
      if canRetry {
        HStack(spacing: Theme.Spacing.lg) {
          Button(String(localized: "Retry now", comment: "Outbox action")) { Task { await model.retry(item) } }
            .accessibilityIdentifier("settings.outbox.retry")
          Button(discardTitle(of: item), role: .destructive) {
            Task { await model.discard(item) }
          }
          .accessibilityIdentifier("settings.outbox.discard")
        }
        .buttonStyle(.borderless)
        .themeFont(.footnote, weight: .medium)
      }
    }
    .swipeActions(edge: .trailing) {
      if item.canDiscard {
        Button(discardTitle(of: item), role: .destructive) {
          Task { await model.discard(item) }
        }
      }
    }
    .contextMenu {
      if canRetry {
        Button(String(localized: "Retry now", comment: "Outbox action"), systemImage: "arrow.clockwise") {
          Task { await model.retry(item) }
        }
      }
      if item.canDiscard {
        Button(discardTitle(of: item), systemImage: "trash", role: .destructive) {
          Task { await model.discard(item) }
        }
      }
    }
  }

  /// A queued server delete is not discarded, the app stops trying to send it.
  private func discardTitle(of item: QueuedItem) -> String {
    item.kind.discardStopsTrying
      ? String(localized: "Stop trying", comment: "Outbox action on a discarded memo's queued removal")
      : String(localized: "Discard", comment: "Outbox action")
  }

  /// What it is and how long it has waited: "Voice reply · 4 min ago".
  private func detail(of item: QueuedItem) -> String {
    let age = item.queuedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    return "\(item.kind.title) · \(age)"
  }

  private func statusText(of state: QueuedItem.State) -> String {
    switch state {
    case .recording: String(localized: "Recording", comment: "Outbox item state")
    case .waiting: String(localized: "Waiting", comment: "Outbox item state")
    case .sending: String(localized: "Sending", comment: "Outbox item state")
    case .failed(let retryAt?, _):
      String(localized: "Retry \(retryAt.formatted(.relative(presentation: .numeric)))", comment: "Outbox item state")
    case .failed(nil, let reason):
      reason ?? String(localized: "Failed", comment: "Outbox item state")
    }
  }
}

extension QueuedItem.Kind {
  fileprivate var systemImage: String {
    switch self {
    case .voiceMemo, .voiceReply: "waveform"
    case .typedMemo: "square.and.pencil"
    case .chatMessage, .textReply: "text.bubble"
    case .removal: "trash"
    }
  }

  fileprivate var title: String {
    switch self {
    case .voiceMemo: String(localized: "Voice memo", comment: "Outbox item kind")
    case .voiceReply: String(localized: "Voice reply", comment: "Outbox item kind")
    case .typedMemo: String(localized: "Typed memo", comment: "Outbox item kind")
    case .chatMessage: String(localized: "Chat message", comment: "Outbox item kind")
    case .textReply: String(localized: "Reply", comment: "Outbox item kind")
    case .removal:
      String(localized: "Discarded memo", comment: "Outbox item kind: its removal from the server is queued")
    }
  }
}

extension QueuedItem.State {
  fileprivate var status: OutboxItemRow.Status {
    switch self {
    case .recording, .waiting: .waiting
    case .sending: .sending
    case .failed: .failed
    }
  }
}
