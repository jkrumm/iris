import IrisCore
import IrisUI
import SwiftUI

/// A memo in the main window's list: a compact two-line row on the list's native selection highlight, no box. The headline (13 pt
/// semibold, up to two lines), then a status dot with the kind and the audio length in 11 pt; the time and the flags sit right, and
/// a transcript row shows a Copy button there while the pointer is over it.
struct MacMemoListRow: View {
  let root: MacCompositionRoot
  let memo: Memo
  @State private var hovering = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.cozy) {
      VStack(alignment: .leading, spacing: Theme.Spacing.macRowLineGap) {
        Text(verbatim: memo.rowHeadline)
          .macFont(.body, weight: .semibold)
          .macRowInk(Theme.Ink.primary)
          .lineLimit(2)
        HStack(spacing: Theme.Spacing.snug) {
          MacRowStatusMark(memo: memo)
          Text(verbatim: memo.macRowMeta.text).lineLimit(1)
        }
        .macFont(.caption)
        .macRowInk(Theme.Ink.muted)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: Theme.Spacing.macRowLineGap) {
        Text(verbatim: memo.timeText).monospacedDigit()
        HStack(spacing: Theme.Spacing.xs) {
          // A transcript row copies from the list, in addition to the context menu: the button takes the flags' place while the
          // pointer is over the row, in a slot of its own height, so the row does not move.
          if hovering, memo.macRowCopyText != nil {
            MacRowCopyButton(root: root, memo: memo).macRowInk(Theme.Ink.muted)
          } else {
            if memo.favorite {
              Image(systemName: "star.fill").foregroundStyle(Theme.Status.warn).accessibilityHidden(true)
            }
            if memo.done {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.good).accessibilityHidden(true)
            }
          }
        }
        .frame(height: memo.macRowCopyText == nil ? nil : Theme.Spacing.macRowCopySize)
      }
      .macFont(.caption)
      .macRowInk(Theme.Ink.muted)
    }
    .opacity(memo.done ? 0.6 : 1)
    .frame(minHeight: Theme.Spacing.macRowMinHeight, alignment: .topLeading)
    .padding(.vertical, Theme.Spacing.macRowVertical)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("mac.list.row")
  }
}
