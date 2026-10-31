import IrisUI
import SwiftUI

/// The outbox in the menu panel, under the header on every page, only while something waits: a count, the reason a stalled
/// upload stopped, and a row per item with Retry now / Discard (the iPhone Settings queue, in a popover's measure).
struct MacOutboxStrip: View {
  let model: MacOutboxModel
  @State private var isExpanded: Bool?

  /// Open by itself while an item is stalled — that is the one that needs the user — and closed for a queue that is only busy.
  private var expanded: Bool { isExpanded ?? !model.stalled.isEmpty }

  var body: some View {
    if model.needsAttention {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        summary
        if model.isUnavailable { notice(Self.unavailableText, id: "mac.outbox.unavailable") }
        if model.saveFailure != nil { notice(Self.saveFailureText, id: "mac.outbox.savefailed") }
        if model.discardFailed { notice(Self.discardFailedText, id: "mac.outbox.discardfailed") }
        if expanded && !model.items.isEmpty {
          // A few rows show whole; a long queue scrolls in a fixed height so it never pushes History out of the popover.
          if model.items.count <= Self.rowsBeforeScrolling {
            rows
          } else {
            ScrollView { rows }
              .frame(height: Self.scrollingHeight)
          }
        }
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.vertical, Theme.Spacing.md)
      .background(Theme.Surface.panel)
      .accessibilityIdentifier("mac.outbox")
      Divider()
    }
  }

  /// More rows than this scroll.
  static let rowsBeforeScrolling = 3
  /// About three rows and their buttons.
  static let scrollingHeight: CGFloat = 200

  private var rows: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      ForEach(model.items) { item in row(item) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var summary: some View {
    Button {
      isExpanded = !expanded
    } label: {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: model.stalled.isEmpty ? "arrow.up.circle" : "exclamationmark.triangle.fill")
          .foregroundStyle(model.stalled.isEmpty ? Theme.Ink.muted : Theme.Status.warn)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
          Text(verbatim: Self.title(count: model.items.count, stalled: model.stalled.count))
            .themeFont(.subheadline, weight: .medium)
            .foregroundStyle(Theme.Ink.primary)
            .accessibilityIdentifier("mac.outbox.title")
          if let reason = Self.reason(of: model.stalled.first) {
            Text(verbatim: reason)
              .themeFont(.footnote)
              .foregroundStyle(Theme.Ink.muted)
              .lineLimit(2)
              .accessibilityIdentifier("mac.outbox.reason")
          }
        }
        Spacer(minLength: Theme.Spacing.sm)
        if !model.items.isEmpty {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .foregroundStyle(Theme.Ink.faint)
            .accessibilityHidden(true)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("mac.outbox.summary")
  }

  private func row(_ item: QueuedItem) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      OutboxItemRow(
        systemImage: item.kind.systemImage, title: item.title, detail: item.detailLine, status: item.state.rowStatus,
        statusText: item.state.text
      )
      .accessibilityIdentifier("mac.outbox.row")
      let canRetry = item.state.canRetry
      if canRetry || item.canDiscard {
        HStack(spacing: Theme.Spacing.lg) {
          if canRetry {
            Button(String(localized: "Retry now", comment: "Outbox action")) { Task { await model.retry(item) } }
              .accessibilityIdentifier("mac.outbox.retry")
          }
          if item.canDiscard {
            Button(item.discardTitle, role: .destructive) { Task { await model.discard(item) } }
              .accessibilityIdentifier("mac.outbox.discard")
          }
        }
        .buttonStyle(.borderless)
        .themeFont(.footnote, weight: .medium)
      }
    }
  }

  private func notice(_ text: String, id: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.warn)
      Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading)
    }
    .themeFont(.footnote)
    .foregroundStyle(Theme.Ink.secondary)
    .accessibilityIdentifier(id)
  }

  // MARK: Words

  static func title(count: Int, stalled: Int) -> String {
    switch (count, stalled) {
    case (0, _): String(localized: "The queue could not be used", comment: "Outbox strip title: the queue is unavailable")
    case (_, 0): String(localized: "\(count) waiting to send", comment: "Outbox strip title: items are on their way")
    default:
      String(localized: "\(stalled) of \(count) could not be sent", comment: "Outbox strip title: stalled items")
    }
  }

  /// The first stalled item's reason, or a generic one: what the user reads before choosing Retry now or Discard.
  static func reason(of item: QueuedItem?) -> String? {
    guard let item, case .failed(nil, let reason) = item.state else { return nil }
    return reason ?? String(localized: "The server did not accept it.", comment: "Outbox strip: a stalled item with no reason")
  }

  static let unavailableText = String(
    localized: "The queue cannot be opened right now. Nothing new is accepted until it can.",
    comment: "Outbox strip: the persistent queue is unavailable")
  static let saveFailureText = String(
    localized: "The queue could not be saved to this Mac. Recordings wait to be sent until it can, and Iris keeps trying.",
    comment: "Outbox strip: the queue cannot be written")
  static let discardFailedText = String(
    localized: "The item could not be discarded because the queue cannot be opened.",
    comment: "Outbox strip: a discard did not reach the queue")
}

extension QueuedItem {
  /// What it is and how long it has waited: "Voice memo · 4 min ago".
  fileprivate var detailLine: String {
    let age = queuedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    return "\(kind.title) · \(age)"
  }

  /// A queued server delete is not discarded, the app stops trying to send it.
  fileprivate var discardTitle: String {
    kind.discardStopsTrying
      ? String(localized: "Stop trying", comment: "Outbox action on a discarded memo's queued removal")
      : String(localized: "Discard", comment: "Outbox action")
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
  fileprivate var rowStatus: OutboxItemRow.Status {
    switch self {
    case .recording, .waiting: .waiting
    case .sending: .sending
    case .failed: .failed
    }
  }

  fileprivate var canRetry: Bool {
    if case .failed = self { true } else { false }
  }

  fileprivate var text: String {
    switch self {
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
