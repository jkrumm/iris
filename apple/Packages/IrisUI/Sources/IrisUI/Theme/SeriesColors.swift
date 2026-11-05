import SwiftUI

/// One series of the charts: a memo kind (or the two catch-alls), identified by the caller's id and coloured by its slot.
/// The app decides which kinds get a palette slot (the most frequent ones) and which fall into `.other`. Colors are
/// checked for contrast in light and dark (the Stats mockup's series set); every chart also names a series in a legend.
public struct VolumeSeries: Hashable, Identifiable, Sendable {
  public enum Slot: Hashable, Sendable {
    /// One of the four distinct palette colors, `0..<paletteCount`.
    case palette(Int)
    /// Every kind that has no slot of its own: a neutral mid grey.
    case other
    /// Memos without a kind (mode `transcribe`).
    case transcript
  }

  public static let paletteCount = 4

  public let id: String
  public let slot: Slot

  public init(id: String, slot: Slot) {
    self.id = id
    self.slot = slot
  }

  public static let other = VolumeSeries(id: "other", slot: .other)
  public static let transcript = VolumeSeries(id: "transcript", slot: .transcript)

  /// A kind with a palette slot; a slot outside `0..<paletteCount` wraps around.
  public static func kind(_ id: String, slot: Int) -> VolumeSeries {
    VolumeSeries(id: id, slot: .palette(((slot % paletteCount) + paletteCount) % paletteCount))
  }

  public var color: Color {
    switch slot {
    case .palette(let index): SeriesPalette.color(at: index)
    case .other: SeriesPalette.other
    case .transcript: Theme.Ink.faint
    }
  }
}

/// The shared series colors: the charts' slots and the kind dots (``KindPalette``) draw from the same four.
enum SeriesPalette {
  static let blue = Color(ColorPair(light: .hex(0x3B78C4), dark: .hex(0x3F7FD0)))
  static let green = Color(ColorPair(light: .hex(0x2E9E6B), dark: .hex(0x2FA070)))
  static let orange = Color(ColorPair(light: .hex(0xC9672C), dark: .hex(0xD0682A)))
  static let purple = Color(ColorPair(light: .hex(0x7656C2), dark: .hex(0x9A80E0)))
  static let other = Color(ColorPair(light: .hex(0x8A8F98), dark: .hex(0x7C828C)))

  static func color(at index: Int) -> Color {
    switch index {
    case 0: blue
    case 1: green
    case 2: orange
    default: purple
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
