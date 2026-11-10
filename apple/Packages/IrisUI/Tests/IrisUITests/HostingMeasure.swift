#if os(macOS)
  import AppKit
  import SwiftUI

  /// A SwiftUI view in an `NSHostingView` of a fixed width inside an off-screen window, measured by its fitting height: how
  /// the height tests and the benchmark lay a reply out.
  @MainActor
  final class HostingMeasure {
    let width: CGFloat
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let window: NSWindow

    init(width: CGFloat = 390) {
      self.width = width
      _ = NSApplication.shared
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered,
        defer: false)
      window.contentView = hosting
    }

    func show<Content: View>(_ view: Content) {
      hosting.rootView = AnyView(view.frame(width: width).fixedSize(horizontal: false, vertical: true))
    }

    func layout() -> CGFloat {
      hosting.layoutSubtreeIfNeeded()
      return hosting.fittingSize.height
    }

    func spinRunLoop() {
      RunLoop.current.run(mode: .default, before: Date())
    }

    /// The height once SwiftUI stopped changing it (Textual parses in an `onChange`, so the first pass is empty).
    func settledHeight() -> CGFloat {
      var height = layout()
      var stable = 0
      for _ in 0..<40 where stable < 3 {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        let next = layout()
        stable = next == height ? stable + 1 : 0
        height = next
      }
      return height
    }

    func height<Content: View>(of view: Content) -> CGFloat {
      show(view)
      return settledHeight()
    }
  }
#endif
