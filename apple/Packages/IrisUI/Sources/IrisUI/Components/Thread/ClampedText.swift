import SwiftUI

/// A long text folded to what is worth reading first, with a Show full message / Show less button. The text is folded only when it
/// runs past `lineLimit` lines (two hidden copies, one at full height and one clamped, tell); then it shows the `gist` when there
/// is one, else its first `lineLimit` lines. The bubble is one view whichever it shows, so the gist arriving later swaps the
/// content in place (animated) and keeps an expansion the reader already made.
///
/// A text that fits has neither gist nor button. The gist is not selectable, so a long press reaches the bubble's Copy, which
/// copies the full text.
struct ClampedText: View {
  let text: String
  let gist: String?
  let role: Theme.TextRole
  let lineLimit: Int
  @State private var isExpanded: Bool
  @State private var clampedHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0

  init(text: String, gist: String? = nil, role: Theme.TextRole, lineLimit: Int, startsExpanded: Bool = false) {
    _isExpanded = State(initialValue: startsExpanded)
    self.text = text
    let trimmed = gist?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.gist = trimmed?.isEmpty == false ? trimmed : nil
    self.role = role
    self.lineLimit = lineLimit
  }

  /// Before the first measure the text is taken to be long when it has a gist (the server writes one only for a long
  /// transcript), so the common case does not flash the whole text and fold it a frame later.
  private var fits: Bool {
    fullHeight > 0 ? fullHeight <= clampedHeight + 1 : gist == nil
  }

  private var shownGist: String? { isExpanded || fits ? nil : gist }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      shown
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { measures }
        .animation(.snappy, value: shownGist != nil)
      if isExpanded || !fits {
        Button {
          withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
          Group {
            if isExpanded {
              Text("Show less", bundle: #bundle, comment: "Collapses a long transcript to its gist or first lines")
            } else {
              Text(
                "Show full message", bundle: #bundle,
                comment: "Expands a long transcript that is folded to its gist or its first lines")
            }
          }
          .themeFont(.footnote, weight: .semibold)
          .foregroundStyle(Theme.Accent.tint)
          .frame(minHeight: Theme.Spacing.tapTarget, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.transcript.more")
      }
    }
  }

  @ViewBuilder private var shown: some View {
    if let shownGist {
      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        Text("Summary", bundle: #bundle, comment: "Label over the short gist a long transcript is folded to")
          .themeFont(.caption, weight: .semibold)
          .foregroundStyle(Theme.Ink.secondary)
        Text(verbatim: shownGist)
          .themeFont(role)
          .foregroundStyle(Theme.Ink.primary)
          .accessibilityIdentifier("thread.turn.gist")
      }
    } else {
      Text(verbatim: text)
        .themeFont(role)
        .foregroundStyle(Theme.Ink.primary)
        .textSelection(.enabled)
        .lineLimit(isExpanded ? nil : lineLimit)
    }
  }

  /// The text at full height and clamped to `lineLimit`, both at the width the bubble gives it.
  private var measures: some View {
    ZStack {
      Text(verbatim: text)
        .themeFont(role)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
      Text(verbatim: text)
        .themeFont(role)
        .lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { clampedHeight = $0 }
    }
    .hidden()
  }
}
