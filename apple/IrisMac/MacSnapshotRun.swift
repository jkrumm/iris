import AppKit
import Foundation
import os
import SwiftUI

/// `-IrisMacSnapshot <directory>`: writes PNGs of the app's own windows and quits. The mini has no Screen Recording grant,
/// so `screencapture` cannot see the app; a window renders itself without one. Used with `-IrisFakeData` and
/// `-IrisMacPanelWindow` for the screenshot proof of a PR.
@MainActor
struct MacSnapshotRun {
  static let argument = "-IrisMacSnapshot"
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "snapshot")

  let directory: URL
  let root: MacCompositionRoot
  /// The memo the detail panel is opened on.
  let detailMemoID: String

  init?(arguments: [String], root: MacCompositionRoot, detailMemoID: String = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34") {
    guard let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1) else { return nil }
    directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    self.root = root
    self.detailMemoID = detailMemoID
  }

  func run() async {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(4))
    write(windowTitled: "Iris panel", as: "history")
    root.openDetail(detailMemoID)
    try? await Task.sleep(for: .seconds(2))
    // The detail window of an app that was launched in the background is not drawn until the app is active (a click), so the
    // panel's content is rendered in a hosting view of its own: the same `MacMemoDetailPanel`, the size the window opens at.
    let hosting = NSHostingView(rootView: MacMemoDetailPanel(root: root))
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 760)
    let offscreen = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    offscreen.title = "Iris detail snapshot"
    offscreen.contentView = hosting
    offscreen.orderFrontRegardless()
    try? await Task.sleep(for: .seconds(2))
    write(windowTitled: "Iris detail snapshot", as: "detail")
    offscreen.close()
    root.page = .settings
    try? await Task.sleep(for: .seconds(1))
    write(windowTitled: "Iris panel", as: "settings")
    NSApp.terminate(nil)
  }

  private func write(windowTitled title: String, as name: String) {
    guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }), let view = window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      Self.logger.error("no visible window titled \(title, privacy: .public)")
      return
    }
    Self.logger.notice("\(title, privacy: .public): \(window.frame.debugDescription, privacy: .public)")
    window.displayIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: directory.appending(path: "\(name).png"))
  }
}
