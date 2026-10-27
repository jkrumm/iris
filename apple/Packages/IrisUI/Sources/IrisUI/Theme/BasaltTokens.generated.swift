// GENERATED FILE. DO NOT EDIT.
// Source: basalt-ui 2.29.0 (the `--vx-*` tokens, read via `basalt-ui/tokens`).
// Regenerate: cd apple/tools && bun install --frozen-lockfile && bun gen-theme.ts
// CI gate:    cd apple/tools && bun gen-theme.ts --check

/// An sRGB color with straight alpha; components are 0...1.
struct RGBA: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

/// One token resolved per color scheme.
struct ColorPair: Equatable, Sendable {
  var light: RGBA
  var dark: RGBA
}

enum BasaltTokens {
  static let basaltVersion = "2.29.0"

  enum Colors {
    static let surfaceBg = ColorPair(
      light: RGBA(red: 0.94902, green: 0.94902, blue: 0.960784, alpha: 1.0),
      dark: RGBA(red: 0.152941, green: 0.152941, blue: 0.164706, alpha: 1.0))
    static let surfacePanel = ColorPair(
      light: RGBA(red: 0.980392, green: 0.980392, blue: 0.992157, alpha: 1.0),
      dark: RGBA(red: 0.168627, green: 0.168627, blue: 0.180392, alpha: 1.0))
    static let surfaceElevated = ColorPair(
      light: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
      dark: RGBA(red: 0.219608, green: 0.219608, blue: 0.231373, alpha: 1.0))
    static let surfaceSubtle = ColorPair(
      light: RGBA(red: 0.956863, green: 0.956863, blue: 0.972549, alpha: 1.0),
      dark: RGBA(red: 0.196078, green: 0.196078, blue: 0.207843, alpha: 1.0))
    static let surfaceBorder = ColorPair(
      light: RGBA(red: 0.886275, green: 0.886275, blue: 0.898039, alpha: 1.0),
      dark: RGBA(red: 0.266667, green: 0.266667, blue: 0.278431, alpha: 1.0))
    static let surfaceHairline = ColorPair(
      light: RGBA(red: 0.917647, green: 0.917647, blue: 0.933333, alpha: 1.0),
      dark: RGBA(red: 0.305882, green: 0.305882, blue: 0.317647, alpha: 1.0))
    static let ink = ColorPair(
      light: RGBA(red: 0.14902, green: 0.14902, blue: 0.160784, alpha: 1.0),
      dark: RGBA(red: 0.898039, green: 0.898039, blue: 0.913725, alpha: 1.0))
    static let ink2 = ColorPair(
      light: RGBA(red: 0.25098, green: 0.25098, blue: 0.262745, alpha: 1.0),
      dark: RGBA(red: 0.866667, green: 0.866667, blue: 0.882353, alpha: 1.0))
    static let muted = ColorPair(
      light: RGBA(red: 0.321569, green: 0.321569, blue: 0.333333, alpha: 1.0),
      dark: RGBA(red: 0.831373, green: 0.831373, blue: 0.847059, alpha: 1.0))
    static let faint = ColorPair(
      light: RGBA(red: 0.411765, green: 0.411765, blue: 0.423529, alpha: 1.0),
      dark: RGBA(red: 0.654902, green: 0.654902, blue: 0.666667, alpha: 1.0))
    static let accent = ColorPair(
      light: RGBA(red: 0.262745, green: 0.454902, blue: 0.65098, alpha: 1.0),
      dark: RGBA(red: 0.635294, green: 0.764706, blue: 0.941176, alpha: 1.0))
    static let accentFill = ColorPair(
      light: RGBA(red: 0.262745, green: 0.454902, blue: 0.65098, alpha: 1.0),
      dark: RGBA(red: 0.262745, green: 0.454902, blue: 0.65098, alpha: 1.0))
    static let onAccent = ColorPair(
      light: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
      dark: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    static let divider = ColorPair(
      light: RGBA(red: 0.14902, green: 0.14902, blue: 0.160784, alpha: 0.09),
      dark: RGBA(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08))
    static let statusExcellent = ColorPair(
      light: RGBA(red: 0.160784, green: 0.65098, blue: 0.203922, alpha: 1.0),
      dark: RGBA(red: 0.262745, green: 0.74902, blue: 0.301961, alpha: 1.0))
    static let statusGood = ColorPair(
      light: RGBA(red: 0.184314, green: 0.466667, blue: 0.294118, alpha: 1.0),
      dark: RGBA(red: 0.321569, green: 0.752941, blue: 0.486275, alpha: 1.0))
    static let statusWarn = ColorPair(
      light: RGBA(red: 0.576471, green: 0.372549, blue: 0.0, alpha: 1.0),
      dark: RGBA(red: 0.901961, green: 0.647059, blue: 0.239216, alpha: 1.0))
    static let statusBad = ColorPair(
      light: RGBA(red: 0.709804, green: 0.25098, blue: 0.239216, alpha: 1.0),
      dark: RGBA(red: 0.996078, green: 0.505882, blue: 0.470588, alpha: 1.0))
    static let statusNeutral = ColorPair(
      light: RGBA(red: 0.443137, green: 0.443137, blue: 0.478431, alpha: 1.0),
      dark: RGBA(red: 0.631373, green: 0.631373, blue: 0.666667, alpha: 1.0))
  }

  /// Corner radii in points.
  enum Radius {
    static let card: Double = 10.0
    static let ctrl: Double = 6.0
    static let tight: Double = 5.0
    static let fine: Double = 4.0
    static let floating: Double = 11.0
  }

  /// Stack rhythm in points (`--vx-space-stack-*`).
  enum Spacing {
    static let xs: Double = 4.0
    static let sm: Double = 8.0
    static let md: Double = 12.0
    static let lg: Double = 16.0
    static let xl: Double = 24.0
  }

  /// Type scale in points (`--vx-text-*`).
  enum TextSize {
    static let nano: Double = 10.0
    static let micro: Double = 11.0
    static let xs: Double = 12.0
    static let sm: Double = 13.0
    static let md: Double = 15.0
    static let lg: Double = 16.0
    static let xl: Double = 18.0
    static let h2: Double = 21.0
    static let kpi: Double = 22.0
    static let h1: Double = 26.0
    static let display: Double = 30.0
  }
}
