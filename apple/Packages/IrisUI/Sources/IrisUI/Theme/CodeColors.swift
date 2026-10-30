import SwiftUI

/// The syntax colors of code blocks: JetBrains Light (light) and JetBrains Dark, the Darcula family (dark). Values are
/// the `syntax` entries of the Zed "JetBrains Themes" extension (the owner's Zed runs JetBrains Dark), mapped onto the
/// highlighter's token names; the block surface is the theme's editor background with basalt-ui's border. Not generated:
/// basalt-ui ships no syntax tokens (its web code blocks use Shiki's GitHub themes). The table is in TDD §4.
public enum CodeColors {
  /// The block surface (the editor background of the two JetBrains themes).
  public static let background = pair(light: 0xFFFFFF, dark: 0x1E1F22)
  /// Text that no token claims: identifiers, operators, brackets.
  public static let plain = pair(light: 0x080808, dark: 0xBCBEC4)
  public static let keyword = pair(light: 0x0033B3, dark: 0xCF8E6D)
  public static let string = pair(light: 0x067D17, dark: 0x6AAB73)
  public static let number = pair(light: 0x1750EB, dark: 0x2AACB8)
  public static let comment = pair(light: 0x8C8C8C, dark: 0x7A7E85)
  public static let docComment = pair(light: 0x8C8C8C, dark: 0x5F826B)
  public static let function = pair(light: 0x00627A, dark: 0x6AA2D7)
  public static let type = pair(light: 0xA04908, dark: 0xA6BB77)
  /// Constants, properties and enum-like names.
  public static let constant = pair(light: 0x871094, dark: 0xC77DBB)
  public static let tag = pair(light: 0x0033B3, dark: 0xD5B778)
  public static let attribute = pair(light: 0x9E880D, dark: 0xB3AE60)
  public static let link = pair(light: 0x00627A, dark: 0x57AAF7)
  public static let escape = pair(light: 0x0037A6, dark: 0xCF8E6D)
  /// The line-number and language-label gray of the block header.
  public static let label = pair(light: 0x7A7A7A, dark: 0x868A91)

  private static func pair(light: Int, dark: Int) -> Color {
    Color(ColorPair(light: rgba(light), dark: rgba(dark)))
  }

  private static func rgba(_ hex: Int) -> RGBA {
    RGBA(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
      alpha: 1)
  }
}
