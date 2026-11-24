import CoreGraphics
import SwiftUI

/// How a conversation plays its answers: where a memo's reply stands, which answers can speak, and what the player's controls do.
/// With it, every finished answer that can speak carries the inline ``ReplyPlayer`` in its footer. `playback` is read inside the
/// footer's own body, so a position that moves four times a second redraws that footer and never the whole list.
public struct ReplyControls {
  public var playback: (String) -> ReplyPlayback
  public var canPlay: (String) -> Bool
  /// The round button: starts the summary when nothing of this memo plays, else pauses or resumes what the player holds.
  public var onToggle: (String) -> Void
  /// A form picked from the player's menu: starts it from the top, or pauses it when it is the one that plays.
  public var onPlay: (String, ReplyPlayChoice) -> Void
  public var onSeek: (String, Double) -> Void

  public init(
    playback: @escaping (String) -> ReplyPlayback, canPlay: @escaping (String) -> Bool,
    onToggle: @escaping (String) -> Void, onPlay: @escaping (String, ReplyPlayChoice) -> Void,
    onSeek: @escaping (String, Double) -> Void
  ) {
    self.playback = playback
    self.canPlay = canPlay
    self.onToggle = onToggle
    self.onPlay = onPlay
    self.onSeek = onSeek
  }
}

/// The footer of an answer: reads the memo's playback here, so only this view redraws while the reply plays.
private struct ReplyFooter: View {
  let controls: ReplyControls
  let memoID: String

  var body: some View {
    ReplyPlayer(
      playback: controls.playback(memoID), onToggle: { controls.onToggle(memoID) },
      onPlay: { controls.onPlay(memoID, $0) }, onSeek: { controls.onSeek(memoID, $0) })
  }
}

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
      textRole: nil, rowSpacing: Theme.Spacing.turnGap, failedText: .callout, userIdentifier: nil,
      assistantIdentifier: nil, failedIdentifier: "thread.turn.failed")

    public static let mac = Style(
      textRole: .footnote, rowSpacing: Theme.Spacing.turnGap, failedText: .macBody,
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
  private let reply: ReplyControls?

  /// - Parameters:
  ///   - dayTitle: The title of the line that opens an exchange (the app owns the day formatter).
  ///   - plainText: What Copy puts on the pasteboard for an answer, given its markdown; the app owns the markdown stripping.
  ///   - onCopy: Adds Copy to a bubble's long press with the text to copy; `nil` leaves the bubbles without it.
  ///   - onDetails: Called with a memo's id; non-nil adds Details to the long press of the memo's bubbles.
  ///   - onRetry: Called with a memo's id; non-nil shows Retry under a failed turn.
  ///   - reply: Non-nil puts the play control (summary or full) under every finished answer that can speak.
  public init(
    turns: [ConversationTurn], style: Style, dayTitle: @escaping (Date) -> String,
    plainText: @escaping (String) -> String = { $0 }, onCopy: ((String) -> Void)? = nil,
    onOpenImage: @escaping (CGImage) -> Void = { _ in }, onDetails: ((String) -> Void)? = nil,
    onRetry: ((String) -> Void)? = nil, reply: ReplyControls? = nil
  ) {
    self.turns = turns
    self.style = style
    self.dayTitle = dayTitle
    self.plainText = plainText
    self.onCopy = onCopy
    self.onOpenImage = onOpenImage
    self.onDetails = onDetails
    self.onRetry = onRetry
    self.reply = reply
  }

  /// The lines between exchanges, by the id of the question they open (never the first turn's): `true` when the line carries its day,
  /// which it does once per calendar day, before the first question of that day; `false` for a plain line between two exchanges of a
  /// day already named. A question without a date has no day to name.
  static func exchangeLines(of turns: [ConversationTurn], calendar: Calendar = .current) -> [String: Bool] {
    var lines: [String: Bool] = [:]
    var namedDay: Date?
    for (index, turn) in turns.enumerated() {
      guard index > 0, case .user = turn.content else { continue }
      guard let date = turn.date else {
        lines[turn.id] = false
        continue
      }
      let day = calendar.startOfDay(for: date)
      lines[turn.id] = day != namedDay
      namedDay = day
    }
    return lines
  }

  public var body: some View {
    let lines = Self.exchangeLines(of: turns)
    return ForEach(Array(turns.enumerated()), id: \.element.id) { _, turn in
      VStack(alignment: .leading, spacing: style.rowSpacing) {
        // A question after an answer opens a new exchange; the line names its day the first time that day shows.
        if let titled = lines[turn.id] { ExchangeDivider(title: titled ? turn.date.map(dayTitle) : nil) }
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
    let speaking = isStreaming ? nil : speakingMemoID(of: turn)
    return AssistantTurnView(
      markdown: markdown, time: time(turn.date), mermaid: mermaid, artifacts: artifacts,
      identifier: isStreaming ? "thread.turn.streaming" : style.assistantIdentifier ?? "thread.turn.assistant",
      textRole: style.textRole ?? .callout,
      onOpenImage: onOpenImage, onCopy: copy(plainText(markdown)), onDetails: details(of: turn),
      isStreaming: isStreaming, activity: activity, hasFooter: speaking != nil
    ) {
      if let reply, let speaking { ReplyFooter(controls: reply, memoID: speaking) }
    }
  }

  /// The memo whose play control the answer carries: a finished answer of a memo that can speak.
  private func speakingMemoID(of turn: ConversationTurn) -> String? {
    guard let reply, let memoID = turn.memoID, reply.canPlay(memoID) else { return nil }
    return memoID
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
