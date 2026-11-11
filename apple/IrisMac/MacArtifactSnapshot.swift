#if DEBUG
  import AppKit
  import Foundation
  import IrisUI
  import SwiftUI
  import WebKit
  import os

  /// The artifact island spike on the Mac (`-IrisMacSnapshot`): the demo in a window of its own in light and dark, and what N islands
  /// cost in memory (the app's own footprint and the WebKit WebContent processes that appeared since the baseline).
  extension MacSnapshotRun {
    private static let artifactLogger = Logger(subsystem: "com.jkrumm.iris", category: "snapshot")
    private static let islandSettle: Duration = .seconds(4)
    private static let memorySettle: Duration = .seconds(6)

    func writeArtifactIslands() async {
      var lines: [String] = []

      // The main window is a scene window the window server draws (one made here came out blank): its content is swapped for the
      // demo for the two pictures, then put back.
      let mainTitle = String(localized: "Iris", comment: "Main window title")
      if let window = NSApp.windows.first(where: { $0.title == mainTitle && $0.isVisible }),
        let original = window.contentView
      {
        window.setContentSize(NSSize(width: 480, height: 640))
        window.contentView = NSHostingView(rootView: ArtifactIslandDemo(islands: 1))
        window.appearance = NSAppearance(named: .aqua)
        try? await Task.sleep(for: Self.islandSettle)
        await writeWithWebContent(window, as: "artifact-island")
        window.appearance = NSAppearance(named: .darkAqua)
        try? await Task.sleep(for: Self.islandSettle)
        await writeWithWebContent(window, as: "artifact-island-dark")
        window.contentView = original
        window.appearance = nil
        try? await Task.sleep(for: .seconds(2))
      } else {
        let windows = NSApp.windows.map { "\($0.title) visible=\($0.isVisible)" }.joined(separator: ", ")
        Self.artifactLogger.error(
          "no visible main window for the artifact island; windows: \(windows, privacy: .public)")
      }
      let baseline = await Self.webContentProcesses()
      lines.append("baseline \(Self.describe(processes: baseline, baseline: baseline))")

      for count in [1, 5, 10] {
        // l10n:ignore window title of a verification window
        let memoryWindow = Self.openDemoWindow(islands: count, title: "Artifact islands \(count)")
        try? await Task.sleep(for: Self.memorySettle)
        let now = await Self.webContentProcesses()
        lines.append("islands=\(count) \(Self.describe(processes: now, baseline: baseline))")
        Self.close(memoryWindow)
        try? await Task.sleep(for: .seconds(1))
      }

      do {
        try (lines.joined(separator: "\n") + "\n").write(
          to: directory.appending(path: "artifact-memory.txt"), atomically: true, encoding: .utf8)
      } catch {
        Self.artifactLogger.error("artifact-memory.txt not written: \(String(describing: error), privacy: .public)")
      }
    }

    /// The sample reply's cards and the viewer on the sample document, light and dark: the main window's content is swapped like
    /// for the island, and the web content gets time to render.
    func writeArtifactScreens() async {
      let mainTitle = String(localized: "Iris", comment: "Main window title")
      guard let window = NSApp.windows.first(where: { $0.title == mainTitle && $0.isVisible }),
        let original = window.contentView
      else {
        Self.artifactLogger.error("no visible main window for the artifact screens")
        return
      }
      window.setContentSize(NSSize(width: 480, height: 640))
      for (sample, name) in [(ArtifactSample.cards, "artifact-cards"), (.viewer, "artifact-viewer")] {
        window.contentView = NSHostingView(rootView: ArtifactSampleScreen(sample: sample))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
          window.appearance = NSAppearance(named: appearance)
          try? await Task.sleep(for: Self.islandSettle)
          await writeWithWebContent(window, as: name + suffix)
        }
      }
      window.contentView = original
      window.appearance = nil
      try? await Task.sleep(for: .seconds(2))
    }

    /// WebKit does not paint into a window it considers occluded (the mini's headless display), so the window server's picture of
    /// the island is empty. The web view's own `takeSnapshot` renders on demand; it is laid over the web view for the capture.
    private func writeWithWebContent(_ window: NSWindow, as name: String) async {
      guard let content = window.contentView else { return }
      var overlays: [NSImageView] = []
      for web in Self.webViews(in: content) {
        guard let image = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()) else { continue }
        let overlay = NSImageView(frame: content.convert(web.bounds, from: web))
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        content.addSubview(overlay)
        overlays.append(overlay)
      }
      try? await Task.sleep(for: .milliseconds(300))
      write(window, as: name, chrome: true)
      for overlay in overlays { overlay.removeFromSuperview() }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private static func openDemoWindow(islands: Int, title: String) -> NSWindow {
      let size = NSRect(x: 0, y: 0, width: 480, height: 640)
      let window = NSWindow(contentRect: size, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = title
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ArtifactIslandDemo(islands: islands))
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return window
    }

    /// Drops the content first, so the islands deinit and their WebContent processes can go.
    private static func close(_ window: NSWindow) {
      window.contentView = nil
      window.close()
    }

    // MARK: Memory

    private struct WebContentProcess {
      let pid: Int32
      let rssMB: Double
      let footprintMB: Double?
    }

    private static func describe(processes: [Int32: WebContentProcess], baseline: [Int32: WebContentProcess]) -> String
    {
      let added = processes.filter { baseline[$0.key] == nil }.map(\.value)
      let usesFootprint = !added.isEmpty && added.allSatisfy { $0.footprintMB != nil }
      let total = added.reduce(0) { $0 + (usesFootprint ? ($1.footprintMB ?? 0) : $1.rssMB) }
      return "webcontent_processes=\(added.count) webcontent_footprint_mb=\(format(total)) "
        + "webcontent_source=\(usesFootprint ? "footprint" : "rss") app_footprint_mb=\(format(appFootprintMB()))"
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    /// This process's `phys_footprint` (what Activity Monitor calls Memory).
    private static func appFootprintMB() -> Double {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      guard result == KERN_SUCCESS else { return 0 }
      return Double(info.phys_footprint) / 1_048_576
    }

    /// Every WebContent process on the machine by pid; the caller subtracts the baseline. `rss` from `ps`, the footprint from
    /// `footprint -p` where the system lets this process read it.
    @concurrent
    private static func webContentProcesses() async -> [Int32: WebContentProcess] {
      guard let listing = run("/bin/ps", ["-axo", "pid=,rss=,comm="]) else { return [:] }
      var result: [Int32: WebContentProcess] = [:]
      for line in listing.split(separator: "\n") where line.contains("WebContent") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let rssKB = Double(fields[1]) else { continue }
        result[pid] = WebContentProcess(pid: pid, rssMB: rssKB / 1024, footprintMB: footprintMB(of: pid))
      }
      return result
    }

    /// The `Footprint: 12 MB` line of `footprint -p <pid>`; nil when the tool refuses or prints something else.
    nonisolated private static func footprintMB(of pid: Int32) -> Double? {
      guard let output = run("/usr/bin/footprint", ["-p", String(pid)]),
        let pattern = try? Regex(#"Footprint:\s+([0-9.]+)\s+(KB|MB|GB)"#),
        let match = output.firstMatch(of: pattern),
        let value = match.output[1].substring.flatMap({ Double($0) }),
        let unit = match.output[2].substring
      else { return nil }
      switch unit {
      case "KB": return value / 1024
      case "GB": return value * 1024
      default: return value
      }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String? {
      let process = Process()
      process.executableURL = URL(filePath: path)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
      } catch {
        return nil
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }
#endif
