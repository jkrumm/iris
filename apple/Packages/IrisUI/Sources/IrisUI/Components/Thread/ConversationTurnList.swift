import CoreGraphics
import SwiftUI

/// The one turn renderer the iPhone's chat and the Mac's detail pane share: per turn the optional line that opens a new exchange,
/// then the bubble, a pending turn with the pipeline's dashes, or a failed turn in the failure colour. The body is only the
/// `ForEach`, so the iPhone embeds it in its `LazyVStack` and the Mac in a `VStack`.
///
/// With `onDetails` set, the last turn of each memo is followed by a quiet Details button that reports the memo's id; a turn
/// without a memo (a reply held on this device) never gets one.
public struct ConversationTurnList: View {
  /// What differs between the platforms.
  public struct Style: Equatable, Sendable {
    public enum FailedText: Equatable, Sendable {
      case callout
      case macBody
    }

    /// The text size of the bubbles; `nil` keeps each bubble's own default (the iPhone's).
    public var textRole: Theme.TextRole?
    public var rowSpacing: CGFloat
    public var failedText: FailedText
    /// `nil` keeps the bubble's own identifier.
    public var userIdentifier: String?
    public var assistantIdentifier: String?
    public var failedIdentifier: String

    public init(
      textRole: Theme.TextRole?, rowSpacing: CGFloat, failedText: FailedText, userIdentifier: String?,
      assistantIdentifier: String?, failedIdentifier: String
    ) {
      self.textRole = textRole
      self.rowSpacing = rowSpacing
      self.failedText = failedText
      self.userIdentifier = userIdentifier
      self.assistantIdentifier = assistantIdentifier
      self.failedIdentifier = failedIdentifier
    }

    public static let phone = Style(
      textRole: nil, rowSpacing: Theme.Spacing.inset, failedText: .callout, userIdentifier: nil,
      assistantIdentifier: nil, failedIdentifier: "thread.turn.failed")

    public static let mac = Style(
      textRole: .footnote, rowSpacing: Theme.Spacing.macTurnGap, failedText: .macBody,
      userIdentifier: "mac.detail.turn.user", assistantIdentifier: "mac.detail.turn.assistant",
      failedIdentifier: "mac.detail.turn.failed")
  }

  private let turns: [ConversationTurn]
  private let style: Style
  private let dayTitle: (Date) -> String
  private let plainText: (String) -> String
  private let onCopy: ((String) -> Void)?
  private let onOpenImage: (CGImage) -> Void
  private let onDetails: ((String) -> Void)?

  /// - Parameters:
  ///   - dayTitle: The title of the line that opens an exchange (the app owns the day formatter).
  ///   - plainText: What Copy puts on the pasteboard for an answer, given its markdown; the app owns the markdown stripping.
  ///   - onCopy: Adds Copy to a bubble's long press with the text to copy; `nil` leaves the bubbles without it.
  ///   - onDetails: Called with a memo's id; non-nil shows the Details button after each memo's last turn.
  public init(
    turns: [ConversationTurn], style: Style, dayTitle: @escaping (Date) -> String,
    plainText: @escaping (String) -> String = { $0 }, onCopy: ((String) -> Void)? = nil,
    onOpenImage: @escaping (CGImage) -> Void = { _ in }, onDetails: ((String) -> Void)? = nil
  ) {
    self.turns = turns
    self.style = style
    self.dayTitle = dayTitle
    self.plainText = plainText
    self.onCopy = onCopy
    self.onOpenImage = onOpenImage
    self.onDetails = onDetails
  }

  public var body: some View {
    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
      VStack(alignment: .leading, spacing: style.rowSpacing) {
        // A question after an answer opens a new exchange.
        if index > 0, case .user = turn.content { ExchangeDivider(title: turn.date.map(dayTitle)) }
        view(for: turn)
        if let onDetails, let memoID = turn.memoID, endsMemo(at: index) {
          detailsButton { onDetails(memoID) }
        }
      }
      .id(turn.id)
      .transition(.opacity)
    }
  }

  /// The turn is the last one of its memo: the next turn belongs to another memo, or there is none.
  private func endsMemo(at index: Int) -> Bool {
    guard index + 1 < turns.count else { return true }
    return turns[index + 1].memoID != turns[index].memoID
  }

  @ViewBuilder private func view(for turn: ConversationTurn) -> some View {
    switch turn.content {
    case .user(let text):
      UserTurnView(
        text: text, time: time(turn.date), identifier: style.userIdentifier ?? "thread.turn.user",
        textRole: style.textRole ?? .subheadline, onCopy: copy(text))
    case .assistant(let markdown, let mermaid):
      AssistantTurnView(
        markdown: markdown, time: time(turn.date), mermaid: mermaid,
        identifier: style.assistantIdentifier ?? "thread.turn.assistant", textRole: style.textRole ?? .callout,
        onOpenImage: onOpenImage, onCopy: copy(plainText(markdown)))
    case .pending(let progress, let caption):
      PendingTurnView(progress: progress, caption: caption)
    case .failed(let message):
      failed(message)
    }
  }

  @ViewBuilder private func failed(_ message: String) -> some View {
    switch style.failedText {
    case .callout:
      Text(verbatim: message)
        .themeFont(.callout)
        .foregroundStyle(Theme.Status.bad)
        .accessibilityIdentifier(style.failedIdentifier)
    case .macBody:
      Text(verbatim: message)
        .macFont(.body)
        .foregroundStyle(Theme.Status.bad)
        .textSelection(.enabled)
        .accessibilityIdentifier(style.failedIdentifier)
    }
  }

  private func copy(_ text: String) -> (() -> Void)? {
    guard let onCopy else { return nil }
    return { onCopy(text) }
  }

  private func detailsButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label {
        Text("Details", bundle: #bundle, comment: "Button under a conversation's memo that opens its details")
      } icon: {
        Image(systemName: "info.circle")
      }
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      .frame(minHeight: Theme.Spacing.tapTarget, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("thread.turn.details")
  }

  /// The clock time only: the day sits in the exchange dividers.
  private func time(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .shortened) ?? ""
  }
}
