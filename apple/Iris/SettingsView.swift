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
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.gutter) {
          ScreenTitle(String(localized: "Settings", comment: "Title of the Settings tab"))
          diagnosticsLink
          connection
          outbox
          setAside
          playback
          RouteConfigEntry(micRules: micRules)
          microphone
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
      }
      .accessibilityIdentifier("settings.view")
      .takeBanner()
      .background(Theme.Surface.background)
      .toolbarVisibility(.hidden, for: .navigationBar)
      .statusBarScrim()
      .task { await model.load() }
      .task { await micRules.load() }
      .task { await model.observeQueue() }
      .refreshable {
        await model.load()
        await micRules.load()
      }
    }
  }

  private var diagnosticsLink: some View {
    SettingsGroup {
      NavigationLink {
        DiagnosticsView(model: diagnostics, history: history, quarantinedFiles: model.quarantinedFiles)
      } label: {
        SettingsLinkRow(
          systemImage: "stethoscope", title: String(localized: "Diagnostics", comment: "Settings row"),
          detail: String(localized: "Copy a memo id for debugging", comment: "Settings row detail"))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("settings.diagnostics")
    }
  }

  private var connection: some View {
    SettingsGroup(title: String(localized: "Connection", comment: "Settings section")) {
      HStack(spacing: Theme.Spacing.rowColumnGap) {
        Text("Server", comment: "Settings row")
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.primary)
        Spacer(minLength: Theme.Spacing.sm)
        connectionLabel
      }
      .settingsRow()
      if let connectionForm { ConnectionForm(model: connectionForm) }
    } footer: {
      if model.connection == .notConfigured {
        Text("Enter the server URL and this device's token to connect.", comment: "Settings connection hint")
          .accessibilityIdentifier("settings.connection.hint")
      } else if let hint = connectionStatus.hint {
        Text(verbatim: hint)
          .accessibilityIdentifier("settings.server.hint")
      }
    }
  }

  /// Spoken replies: a finished memo is read out on its own while the app is open.
  private var playback: some View {
    @Bindable var spokenReplies = spokenReplies
    return SettingsGroup(title: String(localized: "Playback", comment: "Settings section")) {
      Toggle(isOn: $spokenReplies.isOn) {
        HStack(spacing: Theme.Spacing.rowColumnGap) {
          Image(systemName: "speaker.wave.2").foregroundStyle(Theme.Accent.tint).frame(
            width: SettingsRowMetrics.iconWidth)
          Text("Spoken replies", comment: "Settings toggle")
            .themeFont(.subheadline)
            .foregroundStyle(Theme.Ink.primary)
        }
      }
      .tint(Theme.Status.good)
      .settingsRow()
      .accessibilityIdentifier("settings.spokenReplies")
    } footer: {
      Text(
        "When on, the reply to a memo you recorded here is read out as soon as it is done, while Iris is open. Play always speaks it on demand.",
        comment: "Settings spoken replies hint")
    }
  }

  /// The microphone rule of the audio route in use right now.
  private var microphone: some View {
    SettingsGroup(title: String(localized: "Microphone", comment: "Settings section")) {
      MicRuleList(
        routeTitle: micRules.routeTitle,
        routeCaption: String(
          localized: "Recording starts with the microphone you pick for this route.",
          comment: "Settings mic rule caption"),
        choices: micRules.choices, selection: micRules.selection
      ) { uid in
        Task { await micRules.pick(uid) }
      }
      .settingsRow()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings.mic")
    } footer: {
      Text(
        "Rules are kept on this device, one per audio route (for example the car's Bluetooth). Connect to another route to set its rule.",
        comment: "Settings mic rule hint")
    }
  }

  private var connectionStatus: ConnectionStatusLine {
    ConnectionStatusLine(
      connection: model.connection, link: history.link, probedAt: model.probedAt, linkObservedAt: history.linkObservedAt
    )
  }

  private var connectionLabel: some View {
    let status = connectionStatus
    return HStack(spacing: Theme.Spacing.snug) {
      Circle().fill(Self.color(for: status.tone)).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(verbatim: status.title)
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.muted)
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
    SettingsGroup(title: String(localized: "Outbox", comment: "Settings section")) {
      if model.queueUnavailable {
        notice(
          String(
            localized:
              "The outbox cannot be opened, so new memos are not accepted. Iris tries again when you pull to refresh or reopen the app.",
            comment: "Outbox unavailable"), id: "settings.outbox.unavailable")
      }
      if model.resetLeftUnopened {
        notice(
          String(
            localized:
              "The old outbox file was set aside and kept, but a new outbox could not be opened yet. Iris tries again when you pull to refresh or reopen the app.",
            comment: "Outbox reset left unopened"), id: "settings.outbox.resetunopened")
      }
      if model.discardFailed {
        Text(
          "The outbox could not be opened, so nothing was discarded. Try again when it is available.",
          comment: "Outbox discard failed"
        )
        .themeFont(.footnote)
        .foregroundStyle(Theme.Status.bad)
        .settingsRow()
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
        .settingsRow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.outbox.unreadable")
      }
      if model.queueSaveFailure != nil {
        notice(
          String(
            localized:
              "The queue could not be saved to this device. Recordings wait to be sent until it can, and Iris keeps trying.",
            comment: "Outbox save failed"), id: "settings.outbox.savefailed")
      }
      if model.queue.isEmpty && !model.queueUnavailable {
        Text("Nothing waiting. Memos and chat messages that cannot be sent yet queue here.", comment: "Outbox empty")
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .settingsRow()
          .accessibilityIdentifier("settings.outbox.empty")
      } else {
        ForEach(model.queue) { item in
          row(for: item)
        }
      }
    }
    .animation(.snappy, value: model.queue)
  }

  /// A warning line with its triangle, one row of a group.
  private func notice(_ text: String, id: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.rowColumnGap) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.Status.warn)
        .frame(width: SettingsRowMetrics.iconWidth)
      Text(verbatim: text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .themeFont(.footnote)
    .foregroundStyle(Theme.Ink.secondary)
    .settingsRow()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(id)
  }

  /// Files the app set aside instead of deleting: shown with their count and size, shared on request, never removed here.
  @ViewBuilder
  private var setAside: some View {
    let summary = model.setAside
    if !summary.isEmpty {
      SettingsGroup(title: String(localized: "Set-aside files", comment: "Settings section")) {
        HStack(spacing: Theme.Spacing.rowColumnGap) {
          Text("Kept on this device", comment: "Settings set-aside row")
            .themeFont(.subheadline)
            .foregroundStyle(Theme.Ink.primary)
          Spacer(minLength: Theme.Spacing.sm)
          Text(
            "\(summary.count) files · \(SetAsideSummary.size(summary.byteCount))",
            comment: "Settings set-aside count and size"
          )
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
        }
        .settingsRow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.setaside")
        if summary.exceedsBound {
          notice(
            String(
              localized: "That is a lot. Iris never deletes them on its own; share the list to have them looked at.",
              comment: "Settings set-aside bound exceeded"), id: "settings.setaside.large")
        }
        ShareLink(
          item: summary.report,
          preview: SharePreview(String(localized: "Set-aside files", comment: "Share sheet title"))
        ) {
          Label(
            String(localized: "Share or copy the list", comment: "Settings set-aside action"), systemImage: "doc.on.doc"
          )
          .themeFont(.subheadline)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsRow()
        .accessibilityIdentifier("settings.setaside.share")
      } footer: {
        Text(
          "Outbox files that could not be read and recordings no queue entry owned. They are kept, never deleted on their own.",
          comment: "Settings set-aside footer")
      }
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
      if canRetry || item.canDiscard {
        HStack(spacing: Theme.Spacing.lg) {
          if canRetry {
            Button(String(localized: "Retry now", comment: "Outbox action")) { Task { await model.retry(item) } }
              .accessibilityIdentifier("settings.outbox.retry")
          }
          if item.canDiscard {
            Button(discardTitle(of: item), role: .destructive) {
              Task { await model.discard(item) }
            }
            .accessibilityIdentifier("settings.outbox.discard")
          }
        }
        .buttonStyle(.borderless)
        .themeFont(.footnote, weight: .medium)
      }
    }
    .settingsRow()
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

// MARK: Screen chrome shared by Stats, Settings and Diagnostics

/// The large title the mockups draw right under the status bar (a hidden navigation bar leaves no title slot).
struct ScreenTitle: View {
  private let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(verbatim: title)
      .themeFont(.display, weight: .bold)
      .foregroundStyle(Theme.Ink.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, Theme.Spacing.titleTop)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Control size, not spacing: the leading icon column of a row, so labels line up with or without an icon.
enum SettingsRowMetrics {
  static let iconWidth: CGFloat = 24
}

/// One settings group as the render draws it: an uppercase label, a flat card of rows split by hairlines, a footnote.
/// Rows bring their own padding (`settingsRow()`), so a row may also carry its own controls and full-width content.
struct SettingsGroup<Rows: View, Footer: View>: View {
  private let title: String?
  private let rows: Rows
  private let footer: Footer

  init(
    title: String? = nil, @ViewBuilder content: () -> Rows, @ViewBuilder footer: () -> Footer
  ) {
    self.title = title
    self.rows = content()
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title {
        DetailSectionLabel(title)
          .padding(.horizontal, Theme.Spacing.xs)
          .padding(.bottom, Theme.Spacing.sm)
      }
      VStack(alignment: .leading, spacing: 0) {
        Group(subviews: rows) { subviews in
          ForEach(subviews.indices, id: \.self) { index in
            if index > 0 { Divider().overlay(Theme.divider) }
            subviews[index]
          }
        }
      }
      .detailCard()
      footer
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.faint)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.sm)
    }
  }
}

extension SettingsGroup where Footer == EmptyView {
  init(title: String? = nil, @ViewBuilder content: () -> Rows) {
    self.init(title: title, content: content, footer: { EmptyView() })
  }
}

/// A row that opens another screen: icon, title with a line of detail, chevron.
struct SettingsLinkRow: View {
  let systemImage: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: Theme.Spacing.rowColumnGap) {
      Image(systemName: systemImage)
        .foregroundStyle(Theme.Accent.tint)
        .frame(width: SettingsRowMetrics.iconWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
        Text(verbatim: title)
          .themeFont(.subheadline)
          .foregroundStyle(Theme.Ink.primary)
        Text(verbatim: detail)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      Spacer(minLength: Theme.Spacing.sm)
      Image(systemName: "chevron.right")
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(Theme.Ink.faint)
        .accessibilityHidden(true)
    }
    .settingsRow()
    .contentShape(.rect)
  }
}

extension View {
  /// The status-bar region of a screen without a navigation bar, filled with the screen background, so content that
  /// scrolls up under the clock is hidden instead of printed over it.
  func statusBarScrim() -> some View {
    safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 0).background(Theme.Surface.background) }
  }

  /// The padding of a row inside a settings card (`rowx`: 13 / 14 in the mockup; the scale has 12 / 14).
  func settingsRow() -> some View {
    padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.rowVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
