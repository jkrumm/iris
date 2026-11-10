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

/// The detail screen's bottom actions: an icon-only retry (the reply's speech plays from its bubble, ``ReplyPlayButton``; a reply
/// is typed or spoken in the conversation's reply bar) on a glass group. Retry is
/// a menu of steps whose plain tap restarts from `primaryRetryID`; it is absent while `retryOptions` is empty. The symbols are
/// all outline glyphs at one weight; each glass circle sits on a solid disc so nothing reads through it.
public struct DetailActionBar: View {
  private let retryOptions: [DetailRetryOption]
  private let primaryRetryID: String?
  private let onRetry: (String) -> Void

  public init(
    retryOptions: [DetailRetryOption],
    primaryRetryID: String?,
    onRetry: @escaping (String) -> Void
  ) {
    self.retryOptions = retryOptions
    self.primaryRetryID = primaryRetryID
    self.onRetry = onRetry
  }

  public var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.barGap) {
      HStack(spacing: Theme.Spacing.barGap) {
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
