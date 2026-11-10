import Foundation
import SwiftUI

/// The CSS custom properties an island page styles itself with, built from the Theme tokens for one color scheme. Pages use
/// `var(--iris-*)` only, so they follow light and dark without a media query.
enum ArtifactTheme {
  static let bodyFont = "-apple-system, system-ui, sans-serif"
  static let monoFont = "ui-monospace, SFMono-Regular, Menlo, monospace"

  static func variables(for scheme: ColorScheme) -> [String: String] {
    let dark = scheme == .dark
    func color(_ pair: ColorPair) -> String { css(dark ? pair.dark : pair.light) }
    func px(_ value: Double) -> String { "\(format(value))px" }

    typealias Colors = BasaltTokens.Colors
    return [
      "color-scheme": dark ? "dark" : "light",
      "--iris-bg": color(Colors.surfaceBg),
      "--iris-panel": color(Colors.surfacePanel),
      "--iris-elevated": color(Colors.surfaceElevated),
      "--iris-subtle": color(Colors.surfaceSubtle),
      "--iris-border": color(Colors.surfaceBorder),
      "--iris-hairline": color(Colors.surfaceHairline),
      "--iris-divider": color(Colors.divider),
      "--iris-ink": color(Colors.ink),
      "--iris-ink-2": color(Colors.ink2),
      "--iris-muted": color(Colors.muted),
      "--iris-faint": color(Colors.faint),
      "--iris-accent": color(Colors.accent),
      "--iris-accent-fill": color(Colors.accentFill),
      "--iris-on-accent": color(Colors.onAccent),
      "--iris-status-excellent": color(Colors.statusExcellent),
      "--iris-status-good": color(Colors.statusGood),
      "--iris-status-warn": color(Colors.statusWarn),
      "--iris-status-bad": color(Colors.statusBad),
      "--iris-status-neutral": color(Colors.statusNeutral),
      "--iris-radius-card": px(BasaltTokens.Radius.card),
      "--iris-radius-ctrl": px(BasaltTokens.Radius.ctrl),
      "--iris-radius-tight": px(BasaltTokens.Radius.tight),
      "--iris-radius-fine": px(BasaltTokens.Radius.fine),
      "--iris-radius-floating": px(BasaltTokens.Radius.floating),
      "--iris-space-xs": px(BasaltTokens.Spacing.xs),
      "--iris-space-sm": px(BasaltTokens.Spacing.sm),
      "--iris-space-md": px(BasaltTokens.Spacing.md),
      "--iris-space-lg": px(BasaltTokens.Spacing.lg),
      "--iris-space-xl": px(BasaltTokens.Spacing.xl),
      "--iris-text-nano": px(BasaltTokens.TextSize.nano),
      "--iris-text-micro": px(BasaltTokens.TextSize.micro),
      "--iris-text-xs": px(BasaltTokens.TextSize.xs),
      "--iris-text-sm": px(BasaltTokens.TextSize.sm),
      "--iris-text-md": px(BasaltTokens.TextSize.md),
      "--iris-text-lg": px(BasaltTokens.TextSize.lg),
      "--iris-text-xl": px(BasaltTokens.TextSize.xl),
      "--iris-text-h2": px(BasaltTokens.TextSize.h2),
      "--iris-text-kpi": px(BasaltTokens.TextSize.kpi),
      "--iris-text-h1": px(BasaltTokens.TextSize.h1),
      "--iris-text-display": px(BasaltTokens.TextSize.display),
      "--iris-font-body": bodyFont,
      "--iris-font-mono": monoFont,
    ]
  }

  /// The variables as a JSON object, for a script to apply.
  static func json(for scheme: ColorScheme) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: variables(for: scheme), options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  private static func css(_ color: RGBA) -> String {
    let (red, green, blue) = (byte(color.red), byte(color.green), byte(color.blue))
    guard color.alpha < 1 else { return "rgb(\(red), \(green), \(blue))" }
    return "rgba(\(red), \(green), \(blue), \(format(color.alpha)))"
  }

  private static func byte(_ component: Double) -> Int {
    Int((min(max(component, 0), 1) * 255).rounded())
  }

  /// A number without a trailing `.0`, at most three decimals.
  private static func format(_ value: Double) -> String {
    var text = Substring(String(format: "%.3f", value))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return String(text)
  }
}
