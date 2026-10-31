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
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      Self.logger.error("snapshot directory not created: \(String(describing: error), privacy: .public)")
    }
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
    await writeRecordingPanel()
    await writeRefusedPanel()
    NSApp.terminate(nil)
  }

  /// The real floating panel while a take records: the hotkey's path (`toggle`), a scripted level, the panel's own window.
  private func writeRecordingPanel() async {
    root.recording.toggle()
    await root.recording.settled()
    for level in Self.levels {
      root.fakeTake?.level(level)
      try? await Task.sleep(for: .milliseconds(40))
    }
    try? await Task.sleep(for: .seconds(1.5))
    write(windowTitled: RecordingPanelController.title, as: "recording")
    root.recording.cancel()
    await root.recording.settled()
  }

  /// The message a refused microphone leaves in the panel, rendered in a window of its own.
  private func writeRefusedPanel() async {
    let model = RecordingPanelModel(
      engine: FakeTakeEngine(), permission: FakeMicrophonePermission(.denied), isConfigured: { true })
    model.toggle()
    await model.settled()
    let hosting = NSHostingView(rootView: RecordingPanelView(model: model).padding(20))
    hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Iris refused snapshot"
    window.contentView = hosting
    window.orderFrontRegardless()
    try? await Task.sleep(for: .seconds(1))
    write(windowTitled: "Iris refused snapshot", as: "recording-refused")
    window.close()
  }

  /// A speaking voice: quiet, a phrase, a pause, a louder phrase.
  private static let levels: [Float] =
    (0..<60).map { index in
      let phrase = index < 28 || index > 34 ? Float(0.25 + 0.55 * abs(sin(Double(index) * 0.55))) : 0.06
      return phrase
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
    guard let png = rep.representation(using: .png, properties: [:]) else {
      Self.logger.error("\(name, privacy: .public) not encoded as PNG")
      return
    }
    do {
      try png.write(to: directory.appending(path: "\(name).png"))
    } catch {
      Self.logger.error("\(name, privacy: .public) not written: \(String(describing: error), privacy: .public)")
    }
  }
}
