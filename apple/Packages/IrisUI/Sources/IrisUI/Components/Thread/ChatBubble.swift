import SwiftUI

/// Which side of the conversation a bubble sits on.
enum BubbleSide {
  case user
  case assistant
}

/// Gives its one child at most `fraction` of the width it is offered and puts it against the leading (assistant) or trailing
/// (user) edge. The layout itself always takes the whole width, so the row lines up in a stack whatever the bubble's size.
struct BubbleWidth: Layout {
  let fraction: CGFloat
  let side: BubbleSide

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let size = child.sizeThatFits(ProposedViewSize(width: limit(proposal.width), height: proposal.height))
    return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? size.width, height: size.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let child = subviews.first else { return }
    let size = child.sizeThatFits(ProposedViewSize(width: limit(bounds.width), height: nil))
    let x = side == .user ? bounds.maxX - size.width : bounds.minX
    child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
  }

  private func limit(_ width: CGFloat?) -> CGFloat? {
    guard let width, width.isFinite else { return nil }
    return width * fraction
  }
}

/// One message of the conversation: a rounded bubble (the user's in the accent tint on the right, Iris's on the panel surface on
/// the left) with a small time caption under it. The `footer` sits inside the bubble under the content, behind a hairline; with
/// `onCopy` a long press on the bubble offers Copy.
struct ChatBubble<Content: View, Footer: View>: View {
  let side: BubbleSide
  let time: String
  let onCopy: (() -> Void)?
  /// Whether the footer row (and the hairline above it) is drawn. A footer built from an `if` is never an `EmptyView`, so the
  /// caller says when there is nothing to show.
  let hasFooter: Bool
  let content: Content
  let footer: Footer

  init(
    side: BubbleSide, time: String, onCopy: (() -> Void)? = nil, hasFooter: Bool = true,
    @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
  ) {
    self.side = side
    self.time = time
    self.onCopy = onCopy
    self.hasFooter = hasFooter
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    BubbleWidth(fraction: fraction, side: side) {
      VStack(alignment: side == .user ? .trailing : .leading, spacing: Theme.Spacing.bubbleCaptionGap) {
        bubble
        if !time.isEmpty {
          Text(verbatim: time)
            .themeFont(.caption)
            .foregroundStyle(Theme.Ink.faint)
            .padding(.horizontal, Theme.Spacing.bubbleCaptionInset)
        }
      }
    }
  }

  private var fraction: CGFloat {
    side == .user ? Theme.Spacing.bubbleUserWidthFraction : Theme.Spacing.bubbleAssistantWidthFraction
  }

  private var shape: UnevenRoundedRectangle {
    let radius = Theme.Spacing.bubbleRadius
    let tail = Theme.Spacing.bubbleTailRadius
    return UnevenRoundedRectangle(
      topLeadingRadius: radius, bottomLeadingRadius: side == .assistant ? tail : radius,
      bottomTrailingRadius: side == .user ? tail : radius, topTrailingRadius: radius)
  }

  private var bubble: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
      content
      if hasFooter {
        Theme.divider.frame(height: 1)
        footer
      }
    }
    .padding(.horizontal, Theme.Spacing.bubbleInsetHorizontal)
    .padding(.vertical, Theme.Spacing.bubbleInsetVertical)
    .background(side == .user ? Theme.Accent.tint.opacity(0.1) : Theme.Surface.panel, in: shape)
    .overlay {
      shape.strokeBorder(side == .user ? Theme.Accent.tint.opacity(0.25) : Theme.Surface.border, lineWidth: 0.5)
    }
    #if os(iOS)
      .contentShape(.contextMenuPreview, shape)
    #endif
    .contextMenu {
      if let onCopy {
        Button(action: onCopy) {
          Label {
            Text("Copy", bundle: #bundle, comment: "Context menu of a chat bubble: copies its text")
          } icon: {
            Image(systemName: "doc.on.doc")
          }
        }
      }
    }
  }
}

extension ChatBubble where Footer == EmptyView {
  init(side: BubbleSide, time: String, onCopy: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
    self.init(side: side, time: time, onCopy: onCopy, hasFooter: false, content: content, footer: { EmptyView() })
  }
}
