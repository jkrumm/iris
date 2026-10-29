import IrisCore
import IrisUI
import SwiftUI

/// The Settings tab: Diagnostics up front, the server connection, and the outbox queue.
struct SettingsView: View {
  let model: SettingsModel
  let history: HistoryModel
  let diagnostics: DiagnosticsModel
  /// The editable URL and token; nil when the app runs on fakes and has no connection to edit.
  var connectionForm: ConnectionModel?

  var body: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink {
            DiagnosticsView(model: diagnostics, history: history)
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
          .accessibilityIdentifier("settings.server")
          if let connectionForm { ConnectionForm(model: connectionForm) }
        } header: {
          Text("Connection", comment: "Settings section")
        } footer: {
          if model.connection == .notConfigured {
            Text("Enter the server URL and this device's token to connect.", comment: "Settings connection hint")
              .accessibilityIdentifier("settings.connection.hint")
          }
        }
        .listRowBackground(Theme.Surface.panel)

        outbox
      }
      .accessibilityIdentifier("settings.view")
      .takeBanner()
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .navigationTitle(String(localized: "Settings", comment: "Navigation title of the Settings tab"))
      .task { await model.load() }
      .task { await model.observeQueue() }
      .refreshable { await model.load() }
    }
  }

  private var connectionLabel: some View {
    let (text, color): (String, Color) =
      switch model.connection {
      case .notConfigured:
        (String(localized: "Not configured", comment: "Server connection"), Theme.Status.warn)
      case .checking: (String(localized: "Checking…", comment: "Server connection"), Theme.Ink.muted)
      case .connected: (String(localized: "Connected", comment: "Server connection"), Theme.Status.good)
      case .degraded(let names):
        (
          names.isEmpty
            ? String(localized: "Degraded", comment: "Server connection")
            : String(localized: "Degraded · \(names.joined(separator: ", "))", comment: "Server connection"),
          Theme.Status.warn
        )
      case .unreachable: (String(localized: "Unreachable", comment: "Server connection"), Theme.Status.bad)
      }
    return HStack(spacing: Theme.Spacing.sm) {
      Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(verbatim: text).foregroundStyle(Theme.Ink.secondary)
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
          Button(String(localized: "Discard", comment: "Outbox action"), role: .destructive) {
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
        Button(String(localized: "Discard", comment: "Outbox action"), role: .destructive) {
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
        Button(String(localized: "Discard", comment: "Outbox action"), systemImage: "trash", role: .destructive) {
          Task { await model.discard(item) }
        }
      }
    }
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
    }
  }

  fileprivate var title: String {
    switch self {
    case .voiceMemo: String(localized: "Voice memo", comment: "Outbox item kind")
    case .voiceReply: String(localized: "Voice reply", comment: "Outbox item kind")
    case .typedMemo: String(localized: "Typed memo", comment: "Outbox item kind")
    case .chatMessage: String(localized: "Chat message", comment: "Outbox item kind")
    case .textReply: String(localized: "Reply", comment: "Outbox item kind")
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
