import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

extension RGBA {
  var swiftUIColor: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }
}

extension Color {
  /// A color that resolves to `pair.light` or `pair.dark` with the current color scheme.
  init(_ pair: ColorPair) {
    #if canImport(UIKit)
      self.init(
        uiColor: UIColor { traits in
          let rgba = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
          return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        })
    #elseif canImport(AppKit)
      self.init(
        nsColor: NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          let rgba = isDark ? pair.dark : pair.light
          return NSColor(
            srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        })
    #else
      self = pair.light.swiftUIColor
    #endif
  }
}
