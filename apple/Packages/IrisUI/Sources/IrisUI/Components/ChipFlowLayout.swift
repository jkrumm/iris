import SwiftUI

/// Lays chips left to right and wraps them onto the next line when the row is full.
public struct ChipFlowLayout: Layout {
  private let spacing: CGFloat

  public init(spacing: CGFloat = Theme.Spacing.sm) {
    self.spacing = spacing
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(in: proposal.width ?? .infinity, subviews: subviews).size
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let arrangement = arrange(in: bounds.width, subviews: subviews)
    for (subview, origin) in zip(subviews, arrangement.origins) {
      subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing
        lineHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (CGSize(width: widest, height: y + lineHeight), origins)
  }
}
