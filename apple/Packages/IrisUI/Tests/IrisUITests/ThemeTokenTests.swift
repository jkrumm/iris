import SwiftUI
import Testing

@testable import IrisUI

struct ThemeTokenTests {
  private struct Scheme: CustomTestStringConvertible, Sendable {
    let name: String
    let resolve: @Sendable (ColorPair) -> RGBA
    var testDescription: String { name }
  }

  private static let schemes = [
    Scheme(name: "light", resolve: { $0.light }),
    Scheme(name: "dark", resolve: { $0.dark }),
  ]

  /// WCAG 2.x relative luminance of an opaque sRGB color.
  private static func luminance(_ color: RGBA) -> Double {
    func linear(_ c: Double) -> Double {
      c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
  }

  private static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
    let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (high + 0.05) / (low + 0.05)
  }

  @Test("Ink ramp reads on the panel surface (WCAG AA, 4.5:1)", arguments: schemes)
  private func inkContrastOnPanel(scheme: Scheme) {
    let panel = scheme.resolve(BasaltTokens.Colors.surfacePanel)
    let ramp = [
      ("ink", BasaltTokens.Colors.ink),
      ("ink2", BasaltTokens.Colors.ink2),
      ("muted", BasaltTokens.Colors.muted),
      ("faint", BasaltTokens.Colors.faint),
    ]
    for (name, pair) in ramp {
      let ratio = Self.contrast(scheme.resolve(pair), panel)
      #expect(ratio >= 4.5, "\(name) on panel in \(scheme.name) is \(ratio):1")
    }
  }

  @Test("Text on the accent fill reads (WCAG AA, 4.5:1)", arguments: schemes)
  private func onAccentContrast(scheme: Scheme) {
    let ratio = Self.contrast(
      scheme.resolve(BasaltTokens.Colors.onAccent), scheme.resolve(BasaltTokens.Colors.accentFill))
    #expect(ratio >= 4.5, "onAccent on accentFill in \(scheme.name) is \(ratio):1")
  }

  @Test("A color pair resolves to distinct light and dark values")
  func pairResolves() {
    let pair = BasaltTokens.Colors.surfaceBg
    #expect(pair.light != pair.dark)
    #expect(pair.light.alpha == 1)
    #expect((0...1).contains(pair.dark.red))
  }

  @Test("Scales are monotonic")
  func scalesAreMonotonic() {
    let spacing = [Theme.Spacing.xs, Theme.Spacing.sm, Theme.Spacing.md, Theme.Spacing.lg, Theme.Spacing.xl]
    #expect(spacing == spacing.sorted())
    #expect(Theme.Radius.fine < Theme.Radius.tight)
    #expect(Theme.Radius.tight < Theme.Radius.card)
    let sizes = Theme.TextRole.allCases.map(\.baseSize)
    #expect(sizes == sizes.sorted())
  }
}
