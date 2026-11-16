import SwiftUI

/// Text clamped to `lineLimit` lines with a Show all / Show less button, the button only when the text is longer than the clamp
/// (a hidden copy at full height tells). Selection stays on, so a long press still copies a span.
struct ClampedText: View {
  let text: String
  let role: Theme.TextRole
  let lineLimit: Int
  @State private var isExpanded = false
  @State private var clampedHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0

  private var isTruncated: Bool { fullHeight > clampedHeight + 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      Text(verbatim: text)
        .themeFont(role)
        .foregroundStyle(Theme.Ink.primary)
        .textSelection(.enabled)
        .lineLimit(isExpanded ? nil : lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
          // Once expanded the height is the full one: keep the clamped measure from before.
          if !isExpanded { clampedHeight = height }
        }
        .background {
          Text(verbatim: text)
            .themeFont(role)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullHeight = $0 }
        }
      if isExpanded || isTruncated {
        Button {
          withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
          Group {
            if isExpanded {
              Text("Show less", bundle: #bundle, comment: "Collapses a long transcript to its first lines")
            } else {
              Text("Show all", bundle: #bundle, comment: "Expands a long transcript that is cut after a few lines")
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
}
