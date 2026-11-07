import IrisCore
import IrisUI
import SwiftUI

/// A memo in the main window's list: a compact two-line row on the system's selection highlight, no box. The headline (13 pt
/// semibold, up to two lines), then a status dot with the kind and the audio length in 11 pt; the time and the flags sit right.
struct MacMemoListRow: View {
  let memo: Memo

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.cozy) {
      VStack(alignment: .leading, spacing: Theme.Spacing.macRowLineGap) {
        Text(verbatim: memo.rowHeadline)
          .macFont(.body, weight: .semibold)
          .lineLimit(2)
        HStack(spacing: Theme.Spacing.snug) {
          MacRowStatusMark(memo: memo)
          Text(verbatim: memo.macRowMeta.text).lineLimit(1)
        }
        .macFont(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: Theme.Spacing.macRowLineGap) {
        Text(verbatim: memo.timeText).monospacedDigit()
        HStack(spacing: Theme.Spacing.xs) {
          if memo.favorite {
            Image(systemName: "star.fill").foregroundStyle(Theme.Status.warn).accessibilityHidden(true)
          }
          if memo.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.good).accessibilityHidden(true)
          }
        }
      }
      .macFont(.caption)
      .foregroundStyle(.secondary)
    }
    .opacity(memo.done ? 0.6 : 1)
    .frame(minHeight: Theme.Spacing.macRowMinHeight, alignment: .topLeading)
    .padding(.vertical, Theme.Spacing.macRowVertical)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("mac.list.row")
  }
}
