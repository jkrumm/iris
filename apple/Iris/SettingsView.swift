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
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .navigationTitle(String(localized: "Settings", comment: "Navigation title of the Settings tab"))
      .task { await model.load() }
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
      if model.queue.isEmpty {
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
    let status: OutboxItemRow.Status
    let statusText: String
    switch item.state {
    case .waiting:
      (status, statusText) = (.waiting, String(localized: "Waiting", comment: "Outbox item state"))
    case .sending:
      (status, statusText) = (.sending, String(localized: "Sending", comment: "Outbox item state"))
    case .failed(let retryAt):
      (status, statusText) = (
        .failed,
        retryAt.map { String(localized: "Retry \($0.formatted(.relative(presentation: .numeric)))") }
          ?? String(localized: "Failed", comment: "Outbox item state")
      )
    }
    return OutboxItemRow(
      systemImage: item.kind == .voiceMemo ? "waveform" : "text.bubble", title: item.title,
      detail: item.queuedAt.formatted(date: .omitted, time: .shortened), status: status, statusText: statusText)
  }
}
