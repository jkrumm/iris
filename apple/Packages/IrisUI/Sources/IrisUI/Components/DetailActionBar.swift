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

/// The detail screen's bottom actions: icon-only reply and retry (the reply's speech plays from its bubble, ``ReplyPlayButton``) on one glass group. Retry is
/// a menu of steps whose plain tap restarts from `primaryRetryID`; it is absent while `retryOptions` is empty. The symbols are
/// all outline glyphs at one weight; each glass circle sits on a solid disc so nothing reads through it.
public struct DetailActionBar: View {
  private let canReply: Bool
  private let retryOptions: [DetailRetryOption]
  private let primaryRetryID: String?
  private let onReply: () -> Void
  private let onRetry: (String) -> Void

  public init(
    canReply: Bool,
    retryOptions: [DetailRetryOption],
    primaryRetryID: String?,
    onReply: @escaping () -> Void,
    onRetry: @escaping (String) -> Void
  ) {
    self.canReply = canReply
    self.retryOptions = retryOptions
    self.primaryRetryID = primaryRetryID
    self.onReply = onReply
    self.onRetry = onRetry
  }

  public var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.barGap) {
      HStack(spacing: Theme.Spacing.barGap) {
        Button(action: onReply) { icon("arrowshape.turn.up.left", isEnabled: canReply) }
          .disabled(!canReply)
          .accessibilityLabel(
            Text("Reply", bundle: #bundle, comment: "VoiceOver label of the button that answers the memo")
          )
          .accessibilityIdentifier("detail.action.reply")

        // A memo with nothing to restart (a done one) has no retry button at all: a ghost circle reads as broken.
        if !retryOptions.isEmpty {
          Menu {
            ForEach(retryOptions) { option in
              Button(option.title) { onRetry(option.id) }
            }
          } label: {
            icon("arrow.clockwise", isEnabled: true)
          } primaryAction: {
            if let primaryRetryID { onRetry(primaryRetryID) }
          }
          .accessibilityLabel(
            Text("Retry", bundle: #bundle, comment: "VoiceOver label of the button that retries a failed memo")
          )
          .accessibilityIdentifier("detail.action.retry")
        }
      }
    }
    .buttonStyle(.plain)
    .hidesRecordAccessory()
  }

  /// A disabled action keeps its glass but its symbol drops to the faint ink.
  private func icon(_ name: String, isEnabled: Bool) -> some View {
    Image(systemName: name)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(isEnabled ? Theme.Ink.primary : Theme.Ink.faint)
      .frame(width: 56, height: 56)
      .background(Theme.Surface.panel, in: .circle)
      .glassEffect(.regular.interactive(), in: .circle)
  }
}
