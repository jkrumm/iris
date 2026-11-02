import SwiftUI

extension View {
  /// A solid backing for a bar that floats over scrolling content (a search capsule, action circles, a status bar): the
  /// screen background behind the view and out to the screen edge through the safe area, with a short fade on the
  /// inner edge so the cut is not a hard line. Glass over it reads the background colour, never the text that scrolled
  /// under it. Public API only: iOS 26 and 27 draw glass differently, a solid fill is the same on both.
  ///
  /// - Parameter edge: The screen edge the bar sits on. `.bottom` backs a bottom inset, `.top` a status-bar region.
  public func floatingBarBackdrop(edge: VerticalEdge) -> some View {
    background(alignment: edge == .bottom ? .top : .bottom) {
      FloatingBarBackdrop(edge: edge)
    }
  }
}

private struct FloatingBarBackdrop: View {
  let edge: VerticalEdge

  var body: some View {
    Theme.Surface.background
      .ignoresSafeArea(edges: edge == .bottom ? .bottom : .top)
      .overlay(alignment: edge == .bottom ? .top : .bottom) {
        LinearGradient(
          colors: [Theme.Surface.background.opacity(0), Theme.Surface.background],
          startPoint: edge == .bottom ? .top : .bottom, endPoint: edge == .bottom ? .bottom : .top
        )
        .frame(height: Theme.Spacing.xl)
        .offset(y: edge == .bottom ? -Theme.Spacing.xl : Theme.Spacing.xl)
        .allowsHitTesting(false)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
