import SwiftUI

/// The route series of the charts: fixed order, one color each, checked for contrast in light and dark (the
/// Stats mockup's series set). Color carries the route here; every chart also names it in a legend.
public enum VolumeSeries: String, CaseIterable, Identifiable, Sendable {
  case hermes
  case journal
  case tabs
  case unrouted

  public var id: String { rawValue }

  public var color: Color {
    switch self {
    case .hermes: Color(ColorPair(light: .hex(0x3B78C4), dark: .hex(0x3F7FD0)))
    case .journal: Color(ColorPair(light: .hex(0x2E9E6B), dark: .hex(0x2FA070)))
    case .tabs: Color(ColorPair(light: .hex(0xC9672C), dark: .hex(0xD0682A)))
    case .unrouted: Theme.Ink.faint
    }
  }
}

extension RGBA {
  fileprivate static func hex(_ value: Int) -> RGBA {
    RGBA(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255, alpha: 1)
  }
}
