import SwiftUI

/// One entry of the retry menu: the step to restart from.
public struct DetailRetryOption: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// The detail screen's bottom actions: icon-only play (reply speech), reply and retry on one glass group. Retry is
/// a menu of steps whose plain tap restarts from `primaryRetryID`; it is disabled while `retryOptions` is empty.
public struct DetailActionBar: View {
  private let isPlayingReply: Bool
  private let canPlayReply: Bool
  private let canReply: Bool
  private let retryOptions: [DetailRetryOption]
  private let primaryRetryID: String?
  private let onPlayReply: () -> Void
  private let onReply: () -> Void
  private let onRetry: (String) -> Void

  public init(
    isPlayingReply: Bool,
    canPlayReply: Bool,
    canReply: Bool,
    retryOptions: [DetailRetryOption],
    primaryRetryID: String?,
    onPlayReply: @escaping () -> Void,
    onReply: @escaping () -> Void,
    onRetry: @escaping (String) -> Void
  ) {
    self.isPlayingReply = isPlayingReply
    self.canPlayReply = canPlayReply
    self.canReply = canReply
    self.retryOptions = retryOptions
    self.primaryRetryID = primaryRetryID
    self.onPlayReply = onPlayReply
    self.onReply = onReply
    self.onRetry = onRetry
  }

  public var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.md) {
        Button(action: onPlayReply) {
          icon(isPlayingReply ? "stop.fill" : "speaker.wave.2.fill", isEnabled: canPlayReply)
        }
        .disabled(!canPlayReply)
        .accessibilityLabel(
          isPlayingReply
            ? Text("Stop reply", bundle: #bundle, comment: "VoiceOver label of the stop button while the reply plays")
            : Text("Play reply", bundle: #bundle, comment: "VoiceOver label of the button that speaks the reply")
        )
        .accessibilityIdentifier("detail.action.play")

        Button(action: onReply) { icon("arrowshape.turn.up.left.fill", isEnabled: canReply) }
          .disabled(!canReply)
          .accessibilityLabel(
            Text("Reply", bundle: #bundle, comment: "VoiceOver label of the button that answers the memo")
          )
          .accessibilityIdentifier("detail.action.reply")

        Menu {
          ForEach(retryOptions) { option in
            Button(option.title) { onRetry(option.id) }
          }
        } label: {
          icon("arrow.clockwise", isEnabled: !retryOptions.isEmpty)
        } primaryAction: {
          if let primaryRetryID { onRetry(primaryRetryID) }
        }
        .disabled(retryOptions.isEmpty)
        .accessibilityLabel(
          Text("Retry", bundle: #bundle, comment: "VoiceOver label of the button that retries a failed memo")
        )
        .accessibilityIdentifier("detail.action.retry")
      }
    }
    .buttonStyle(.plain)
  }

  /// A disabled action keeps its glass but its symbol drops to the faint ink.
  private func icon(_ name: String, isEnabled: Bool) -> some View {
    Image(systemName: name)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(isEnabled ? Theme.Ink.primary : Theme.Ink.faint)
      .frame(width: 56, height: 56)
      .glassEffect(.regular.interactive(), in: .circle)
  }
}
