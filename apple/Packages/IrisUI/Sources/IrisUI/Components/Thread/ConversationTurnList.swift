import CoreGraphics
import SwiftUI

/// The one turn renderer the iPhone's chat and the Mac's detail pane share: per turn the optional line that opens a new exchange,
/// then the bubble, a pending turn with the pipeline's dashes, or a failed turn in the failure colour. The body is only the
/// `ForEach`, so the iPhone embeds it in its `LazyVStack` and the Mac in a `VStack`.
///
/// With `onDetails` set, a long press on a bubble offers Details and reports the turn's memo id; a turn without a memo (a reply
/// held on this device) never gets one. With `onRetry` set, a failed turn is followed by a Retry button that reports its memo's id.
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

  /// A turn of the user's longer than this many lines is folded to its gist (else its first lines).
  static let userLineLimit = 6

  private let turns: [ConversationTurn]
  private let style: Style
  private let dayTitle: (Date) -> String
  private let plainText: (String) -> String
  private let onCopy: ((String) -> Void)?
  private let onOpenImage: (CGImage) -> Void
  private let onDetails: ((String) -> Void)?
  private let onRetry: ((String) -> Void)?

  /// - Parameters:
  ///   - dayTitle: The title of the line that opens an exchange (the app owns the day formatter).
  ///   - plainText: What Copy puts on the pasteboard for an answer, given its markdown; the app owns the markdown stripping.
  ///   - onCopy: Adds Copy to a bubble's long press with the text to copy; `nil` leaves the bubbles without it.
  ///   - onDetails: Called with a memo's id; non-nil adds Details to the long press of the memo's bubbles.
  ///   - onRetry: Called with a memo's id; non-nil shows Retry under a failed turn.
  public init(
    turns: [ConversationTurn], style: Style, dayTitle: @escaping (Date) -> String,
    plainText: @escaping (String) -> String = { $0 }, onCopy: ((String) -> Void)? = nil,
    onOpenImage: @escaping (CGImage) -> Void = { _ in }, onDetails: ((String) -> Void)? = nil,
    onRetry: ((String) -> Void)? = nil
  ) {
    self.turns = turns
    self.style = style
    self.dayTitle = dayTitle
    self.plainText = plainText
    self.onCopy = onCopy
    self.onOpenImage = onOpenImage
    self.onDetails = onDetails
    self.onRetry = onRetry
  }

  public var body: some View {
    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
      VStack(alignment: .leading, spacing: style.rowSpacing) {
        // A question after an answer opens a new exchange.
        if index > 0, case .user = turn.content { ExchangeDivider(title: turn.date.map(dayTitle)) }
        view(for: turn)
      }
      .id(turn.id)
      .transition(.opacity)
    }
  }

  /// The turn's way into its memo's Details, if the list has one and the turn has a memo.
  private func details(of turn: ConversationTurn) -> (() -> Void)? {
    guard let onDetails, let memoID = turn.memoID else { return nil }
    return { onDetails(memoID) }
  }

  @ViewBuilder private func view(for turn: ConversationTurn) -> some View {
    switch turn.content {
    case .user(let text, let gist):
      UserTurnView(
        text: text, time: time(turn.date), identifier: style.userIdentifier ?? "thread.turn.user",
        textRole: style.textRole ?? .subheadline, onCopy: userCopy(turn.content), onDetails: details(of: turn),
        gist: gist,
        collapsedLineLimit: Self.userLineLimit)
    case .assistant(let markdown, let mermaid, let artifacts):
      assistant(turn, markdown: markdown, mermaid: mermaid, artifacts: artifacts, isStreaming: false, activity: nil)
    case .streaming(let markdown, let activity):
      assistant(turn, markdown: markdown, mermaid: [:], artifacts: [:], isStreaming: true, activity: activity)
    case .working(let lines):
      ActivityTurnView(lines: lines)
    case .pending(let progress, let caption):
      PendingTurnView(progress: progress, caption: caption)
    case .failed(let message):
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        failed(message)
        if let onRetry, let memoID = turn.memoID { retryButton { onRetry(memoID) } }
      }
    }
  }

  /// The one call site of the answer bubble: a streaming turn and the finished reply share it, so SwiftUI keeps the view
  /// (and its state) when `.streaming` becomes `.assistant`.
  private func assistant(
    _ turn: ConversationTurn, markdown: String, mermaid: [Int: MermaidAsset],
    artifacts: [ArtifactAsset.Key: ArtifactAsset], isStreaming: Bool, activity: String?
  ) -> some View {
    AssistantTurnView(
      markdown: markdown, time: time(turn.date), mermaid: mermaid, artifacts: artifacts,
      identifier: isStreaming ? "thread.turn.streaming" : style.assistantIdentifier ?? "thread.turn.assistant",
      textRole: style.textRole ?? .callout,
      onOpenImage: onOpenImage, onCopy: copy(plainText(markdown)), onDetails: details(of: turn),
      isStreaming: isStreaming, activity: activity)
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

  /// Copy on the user's bubble: the full text, whatever the bubble shows (its gist or its first lines).
  func userCopy(_ content: ConversationTurn.Content) -> (() -> Void)? {
    guard case .user(let text, _) = content else { return nil }
    return copy(text)
  }

  private func copy(_ text: String) -> (() -> Void)? {
    guard let onCopy else { return nil }
    return { onCopy(text) }
  }

  private func retryButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label {
        Text("Retry", bundle: #bundle, comment: "Button under a failed turn: runs the memo's failed step again")
      } icon: {
        Image(systemName: "arrow.clockwise")
      }
      .themeFont(.footnote, weight: .semibold)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .tint(Theme.Accent.tint)
    .accessibilityIdentifier("thread.turn.retry")
  }

  /// The clock time only: the day sits in the exchange dividers.
  private func time(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .shortened) ?? ""
  }
}
