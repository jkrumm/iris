import SwiftUI

/// The answer that has not arrived: the speaker line with the pipeline's step dashes and a caption. The finished reply
/// replaces it in the same place.
public struct PendingTurnView: View {
  private let progress: StepProgress
  private let caption: String

  public init(progress: StepProgress, caption: String) {
    self.progress = progress
    self.caption = caption
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      TurnHeader(speaker: .assistant, time: "")
      HStack(spacing: Theme.Spacing.md) {
        StepProgressDashes(progress: progress)
        Text(verbatim: caption)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      .padding(Theme.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .detailCard()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: caption))
    .accessibilityIdentifier("thread.turn.pending")
  }
}
