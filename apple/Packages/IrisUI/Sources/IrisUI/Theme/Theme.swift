import SwiftUI

/// Semantic access to the basalt-ui design tokens. Colors resolve per color scheme.
public enum Theme {
  public enum Surface {
    public static let background = Color(BasaltTokens.Colors.surfaceBg)
    public static let panel = Color(BasaltTokens.Colors.surfacePanel)
    public static let elevated = Color(BasaltTokens.Colors.surfaceElevated)
    public static let subtle = Color(BasaltTokens.Colors.surfaceSubtle)
    public static let border = Color(BasaltTokens.Colors.surfaceBorder)
    public static let hairline = Color(BasaltTokens.Colors.surfaceHairline)
  }

  public enum Ink {
    public static let primary = Color(BasaltTokens.Colors.ink)
    public static let secondary = Color(BasaltTokens.Colors.ink2)
    public static let muted = Color(BasaltTokens.Colors.muted)
    public static let faint = Color(BasaltTokens.Colors.faint)
  }

  public enum Accent {
    /// Accent for text, icons and focus rings.
    public static let tint = Color(BasaltTokens.Colors.accent)
    /// Accent for filled controls; pair with ``onFill``.
    public static let fill = Color(BasaltTokens.Colors.accentFill)
    public static let onFill = Color(BasaltTokens.Colors.onAccent)
  }

  public enum Status {
    public static let excellent = Color(BasaltTokens.Colors.statusExcellent)
    public static let good = Color(BasaltTokens.Colors.statusGood)
    public static let warn = Color(BasaltTokens.Colors.statusWarn)
    public static let bad = Color(BasaltTokens.Colors.statusBad)
    public static let neutral = Color(BasaltTokens.Colors.statusNeutral)
  }

  public static let divider = Color(BasaltTokens.Colors.divider)

  public enum Spacing {
    public static let xs = CGFloat(BasaltTokens.Spacing.xs)
    public static let sm = CGFloat(BasaltTokens.Spacing.sm)
    public static let md = CGFloat(BasaltTokens.Spacing.md)
    public static let lg = CGFloat(BasaltTokens.Spacing.lg)
    public static let xl = CGFloat(BasaltTokens.Spacing.xl)
  }

  public enum Radius {
    public static let card = CGFloat(BasaltTokens.Radius.card)
    public static let control = CGFloat(BasaltTokens.Radius.ctrl)
    public static let tight = CGFloat(BasaltTokens.Radius.tight)
    public static let fine = CGFloat(BasaltTokens.Radius.fine)
    public static let floating = CGFloat(BasaltTokens.Radius.floating)
  }
}
