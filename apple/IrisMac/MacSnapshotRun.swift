#if DEBUG
  import AppKit
  import Foundation
  import IrisCapture
  import IrisUI
  import SwiftUI
  import os

  /// `-IrisMacSnapshot <directory>`: writes PNGs of the app's own windows and quits. The mini has no Screen Recording grant,
  /// so `screencapture` cannot see the app; a window renders itself without one. Used with `-IrisFakeData` and
  /// `-IrisMacPanelWindow` for the screenshot proof of a PR: the popover, the main window (a memo with a reply, one that needs a
  /// route, a thread), the Settings tabs, the onboarding window and the recording panel.
  @MainActor
  struct MacSnapshotRun {
    static let argument = "-IrisMacSnapshot"
    private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "snapshot")

    /// The panel window's title as the app localizes it (the scene is declared with `String(localized:)`).
    private static let panelTitle = String(localized: "Iris panel", comment: "Window title of the verification panel")
    private static let mainTitle = String(localized: "Iris", comment: "Main window title")
    private static let onboardingTitle = String(localized: "Welcome to Iris", comment: "Onboarding window title")

    let directory: URL
    let root: MacCompositionRoot
    /// The sample memos the main window is shown on: one with a reply, a chat thread.
    let replyMemoID: String
    let threadMemoID = SampleData.chatThreadID

    init?(arguments: [String], root: MacCompositionRoot, replyMemoID: String = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34") {
      guard let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1) else {
        return nil
      }
      directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
      self.root = root
      self.replyMemoID = replyMemoID
    }

    func run() async {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        Self.logger.error("snapshot directory not created: \(String(describing: error), privacy: .public)")
      }
      try? await Task.sleep(for: .seconds(4))
      write(windowTitled: Self.panelTitle, as: "menu", chrome: false)
      await writeMainWindow()
      await writeSettings()
      await writeOnboarding()
      await writeRecordingPanel()
      // A long microphone name must truncate, not push Stop out of the panel.
      let long = InputPort(
        uid: "fake-long", name: "Yeti Nano Professional Studio Condenser Microphone (USB)", kind: .usb)
      root.fakeTake?.setMicrophones(Microphones(inputs: [FakeAudioDeviceDirectory.builtIn, long], current: long))
      await writeRecordingPanel(as: "recording-longmic")
      await writeRefusedPanel()
      NSApp.terminate(nil)
    }

    /// The main window with a memo that has a reply and a chat thread selected.
    private func writeMainWindow() async {
      root.show(replyMemoID, source: "snapshot")
      try? await Task.sleep(for: .seconds(3))
      resize(windowTitled: Self.mainTitle, width: Theme.Spacing.windowWidth, height: Theme.Spacing.windowHeight)
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-all")
      root.selectedMemoID = threadMemoID
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-thread")
      // A thread that cannot be read: its own reply and transcript show, with the reason (another memo in between drops the cached model).
      root.selectedMemoID = replyMemoID
      try? await Task.sleep(for: .seconds(1))
      await root.fakeAPI?.enqueueFailure(.transport(.notConnectedToInternet), for: .thread)
      root.selectedMemoID = threadMemoID
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-thread-failed")
      root.selectedMemoID = replyMemoID
      root.scope = .threads
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-filtered")
      root.scope = .all
    }

    /// Each Settings tab, the connection form filled in and probed so the result line is in the picture.
    private func writeSettings() async {
      root.connectionForm.urlText = "https://iris.example.com"
      root.connectionForm.tokenText = "token"
      root.showSettings(source: "snapshot")
      try? await Task.sleep(for: .seconds(2))
      root.connectionTest.test(urlText: root.connectionForm.urlText, tokenText: root.connectionForm.tokenText)
      await root.connectionTest.settled()
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-connection")
      root.settingsTab = .recording
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-recording")
      root.settingsTab = .general
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-general")
    }

    private func writeOnboarding() async {
      root.connectionTest.test(urlText: root.connectionForm.urlText, tokenText: root.connectionForm.tokenText)
      root.showOnboarding(source: "snapshot")
      try? await Task.sleep(for: .seconds(2))
      await root.connectionTest.settled()
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.onboardingTitle, as: "onboarding")
    }

    /// The real floating panel while a take records: the hotkey's path (`toggle`), a scripted level, the panel's own window.
    private func writeRecordingPanel(as name: String = "recording") async {
      root.recording.toggle()
      await root.recording.settled()
      for level in Self.levels {
        root.fakeTake?.level(level)
        try? await Task.sleep(for: .milliseconds(40))
      }
      try? await Task.sleep(for: .seconds(1.5))
      write(windowTitled: RecordingPanelController.title, as: name, chrome: false)
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
      write(windowTitled: "Iris refused snapshot", as: "recording-refused", chrome: false)
      window.close()
    }

    /// A speaking voice: quiet, a phrase, a pause, a louder phrase.
    private static let levels: [Float] =
      (0..<60).map { index in
        let phrase = index < 28 || index > 34 ? Float(0.25 + 0.55 * abs(sin(Double(index) * 0.55))) : 0.06
        return phrase
      }

    // MARK: Writing

    /// The Settings window carries the selected tab's name as its title, so it is found by being the Settings scene's window.
    private func writeSettingsWindow(as name: String) {
      let titles = [
        String(localized: "Connection", comment: "Settings tab"),
        String(localized: "Recording", comment: "Settings tab"),
        String(localized: "General", comment: "Settings tab"),
      ]
      guard let window = NSApp.windows.first(where: { titles.contains($0.title) && $0.isVisible }) else {
        Self.logger.error("no visible Settings window: \(describeWindows(), privacy: .public)")
        return
      }
      write(window, as: name)
    }

    private func resize(windowTitled title: String, width: CGFloat, height: CGFloat) {
      guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else { return }
      window.setContentSize(NSSize(width: width, height: height))
      window.center()
    }

    private func write(windowTitled title: String, as name: String, chrome: Bool = true) {
      guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
        Self.logger.error(
          "no visible window titled \(title, privacy: .public); windows: \(describeWindows(), privacy: .public)")
        return
      }
      write(window, as: name, chrome: chrome)
    }

    /// `chrome`: the whole window as the window server draws it (title bar, toolbar, materials), else the content view alone.
    private func write(_ window: NSWindow, as name: String, chrome: Bool = true) {
      window.displayIfNeeded()
      let rep: NSBitmapImageRep?
      if chrome, let image = Self.windowImage(window) {
        rep = NSBitmapImageRep(cgImage: image)
      } else {
        rep = Self.contentBitmap(of: window)
      }
      Self.logger.notice("\(window.title, privacy: .public): \(window.frame.debugDescription, privacy: .public)")
      guard let png = rep?.representation(using: .png, properties: [:]) else {
        Self.logger.error("\(name, privacy: .public) not encoded as PNG")
        return
      }
      do {
        try png.write(to: directory.appending(path: "\(name).png"))
      } catch {
        Self.logger.error("\(name, privacy: .public) not written: \(String(describing: error), privacy: .public)")
      }
    }

    private static func contentBitmap(of window: NSWindow) -> NSBitmapImageRep? {
      guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return nil
      }
      view.layoutSubtreeIfNeeded()
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep
    }

    /// The window server's picture of one of this app's own windows. `CGWindowListCreateImage` is marked unavailable in the macOS
    /// SDK (ScreenCaptureKit replaces it, and asks for a Screen Recording grant the mini does not have); the symbol is still in
    /// CoreGraphics and answers for an app's own windows without one, so it is looked up at run time. Verification tool only.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
      typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else {
        return nil
      }
      let create = unsafeBitCast(symbol, to: Create.self)
      let includingWindow: UInt32 = 1 << 3
      let boundsIgnoreFraming: UInt32 = 1 << 0
      return create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue()
    }

    private func describeWindows() -> String {
      NSApp.windows.map {
        "\($0.title.isEmpty ? "-" : $0.title) visible=\($0.isVisible) \($0.frame.size.debugDescription)"
      }.joined(separator: ", ")
    }
  }
#endif
