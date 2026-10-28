import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// The system pasteboard behind Diagnostics' copy. A port, so the model is tested without touching the device's.
protocol Pasteboard {
  func copy(_ text: String)
}

#if canImport(UIKit)
  struct SystemPasteboard: Pasteboard {
    func copy(_ text: String) {
      UIPasteboard.general.string = text
    }
  }
#endif
