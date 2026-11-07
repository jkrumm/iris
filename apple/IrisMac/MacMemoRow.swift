import IrisCore
import IrisUI
import SwiftUI

/// One memo in the popover (`mac.html` `.menu .m`): the headline on one line with the time right, then a status dot and the
/// kind / state in muted text. A click opens the memo in the main window; the context menu has the list's actions.
struct MacMemoRow: View {
  let root: MacCompositionRoot
  let model: HistoryModel
  let memo: Memo
  @State private var hovering = false

  var body: some View {
    Button {
      root.show(memo.id)
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.menuRowLineGap) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.cozy) {
          Text(verbatim: memo.rowHeadline)
            .themeFont(.footnote, weight: .semibold)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
          if memo.favorite {
            Image(systemName: "star.fill").foregroundStyle(Theme.Status.warn).accessibilityHidden(true)
          }
          if memo.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.good).accessibilityHidden(true)
          }
          Text(verbatim: memo.timeText)
            .monospacedDigit()
            .foregroundStyle(Theme.Ink.faint)
        }
        .themeFont(.caption)
        HStack(spacing: Theme.Spacing.snug) {
          MacRowStatusMark(memo: memo)
          Text(verbatim: memo.macRowMeta.text).lineLimit(1).truncationMode(.tail)
        }
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      }
      .opacity(memo.done ? 0.55 : 1)
      .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
      .padding(.vertical, Theme.Spacing.menuRowVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(hovering ? Theme.Surface.subtle : .clear, in: .rect(cornerRadius: Theme.Spacing.menuRowRadius))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityIdentifier("mac.history.row")
    .contextMenu { MacMemoContextMenu(actions: MacMemoActions(root: root, model: model), memo: memo) }
  }
}
