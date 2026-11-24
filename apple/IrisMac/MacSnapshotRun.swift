#if DEBUG
  import AppKit
  import Foundation
  import IrisCapture
  import IrisCore
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
    /// Scripts what an update check found, for the Settings and badge pictures; nil when the run has no updater.
    let updateEngine: ScriptedUpdateEngine?
    /// The sample memos the main window is shown on: one with a reply, a chat thread.
    let replyMemoID: String
    let threadMemoID = SampleData.chatFollowUpID

    init?(
      arguments: [String], root: MacCompositionRoot, updateEngine: ScriptedUpdateEngine? = nil,
      replyMemoID: String = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"
    ) {
      guard let index = arguments.firstIndex(of: Self.argument), arguments.indices.contains(index + 1) else {
        return nil
      }
      directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
      self.root = root
      self.updateEngine = updateEngine
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
      await writeDark(windowTitled: Self.panelTitle, as: "menu-dark", chrome: false)
      await writeMainWindow()
      await writeSettings()
      await writeOnboarding()
      await writeRecordingPanel()
      // A long microphone name must not widen the panel: the chip cuts it in the middle.
      let long = InputPort(
        uid: "fake-long", name: "Yeti Nano Professional Studio Condenser Microphone (USB)", kind: .usb)
      root.fakeTake?.setMicrophones(Microphones(inputs: [FakeAudioDeviceDirectory.builtIn, long], current: long))
      await writeRecordingPanel(as: "recording-longmic")
      await writeRefusedPanel()
      await writeArtifactIslands()
      await writeArtifactScreens()
      await writeQuickAsk()
      NSApp.terminate(nil)
    }

    /// The main window with a memo that has a reply and a chat thread selected.
    private func writeMainWindow() async {
      root.show(replyMemoID, source: "snapshot")
      try? await Task.sleep(for: .seconds(3))
      resize(windowTitled: Self.mainTitle, width: Theme.Spacing.windowWidth, height: Theme.Spacing.windowHeight)
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-all")
      await writeDark(windowTitled: Self.mainTitle, as: "window-all-dark")
      await writeShell()
      await writeConversationPlayer()
      await writeSpeakerMenu()
      await writeToolbarStrips()
      await writeShellStates()
      // The memo with a run's steps: waterfall, copy rows, tools, ids.
      await writeDetails(memoID: replyMemoID, names: [("window-details", .aqua), ("window-details-dark", .darkAqua)])
      root.selectedMemoID = threadMemoID
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-thread")
      // The diagram of the first answer has been fetched by now.
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-chat-mermaid")
      // The conversation: Previous and Next between its answers.
      await writeDetails(memoID: threadMemoID, names: [("window-details-thread", .aqua)])
      // A turn in flight: the pending bubble with the pipeline's dashes.
      root.selectedMemoID = SampleData.hermesFollowUpID
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-running")
      await writeStreaming(memoID: SampleData.hermesFollowUpID)
      // A thread that cannot be read: its own reply and transcript show, with the reason (another memo in between drops the cached model).
      root.selectedMemoID = replyMemoID
      try? await Task.sleep(for: .seconds(1))
      await root.fakeAPI?.enqueueFailure(.transport(.notConnectedToInternet), for: .thread)
      root.selectedMemoID = threadMemoID
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-thread-failed")
      // A transcript continued with a second recording: one document of both parts.
      root.selectedMemoID = SampleData.transcriptThreadID
      try? await Task.sleep(for: .seconds(3))
      write(windowTitled: Self.mainTitle, as: "window-transcript")
      await writeTranscriptPane()
      // The transcript memo's Details at desktop density, light and dark.
      await writeDetails(
        memoID: SampleData.transcriptThreadID,
        names: [("window-details-transcript", .aqua), ("window-details-transcript-dark", .darkAqua)])
      root.selectedMemoID = replyMemoID
      root.scope = .threads
      try? await Task.sleep(for: .seconds(2))
      write(windowTitled: Self.mainTitle, as: "window-filtered")
      root.scope = .all
      await writeTranscribeAndFilter()
      await writeNewMemo()
    }

    /// The sidebar and toolbar in the states the shell changes: the server not reachable (the connection line appears), then back
    /// (it goes), and an update waiting (the toolbar badge).
    private func writeShellStates() async {
      // Two favorites, so the sidebar shows its count.
      for memo in root.history.memos.prefix(2) {
        _ = try? await root.fakeAPI?.setFlags(id: memo.id, done: nil, favorite: true, archived: nil)
      }
      await root.history.load()
      try? await Task.sleep(for: .seconds(1))
      await writeSidebar(as: "sidebar-connected")
      await root.fakeAPI?.enqueueFailure(.transport(.notConnectedToInternet), for: .listMemos)
      await root.history.load()
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-unreachable")
      await writeSidebar(as: "sidebar-unreachable")
      await root.history.load()
      try? await Task.sleep(for: .seconds(1))
      updateEngine?.status = .available(version: "0.3.2", build: "820")
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-update")
      updateEngine?.status = .upToDate
    }

    /// The toolbar's audio controls and the speaker's menu: the main window's toolbar comes out blank on a host whose window server has
    /// no display, and a menu is a window of the system's that the window server answers 2 x 1 pixels for. So the toolbar's own
    /// ``MacSpeakerMenu`` and ``MacRecordingButton`` are hosted in a strip of ours, and the menu's entries (``MacSpeakerEntries``) under it, in
    /// the menu's material.
    private func writeSpeakerMenu() async {
      guard let memo = try? await root.fakeAPI?.memo(id: replyMemoID).memo else { return }
      let player = MacAudioPlayer()
      let host = NSHostingView(
        rootView: VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
          HStack(spacing: Theme.Spacing.cozy) {
            MacSpeakerMenu(root: root, player: player, memo: memo)
            MacRecordingButton(root: root, player: player, memo: memo)
          }
          .labelStyle(.iconOnly)
          VStack(alignment: .leading, spacing: Theme.Spacing.snug) { MacSpeakerEntries(onRead: { _ in }) }
            .buttonStyle(.plain)
            .padding(Theme.Spacing.cozy)
            .background(.regularMaterial, in: .rect(cornerRadius: Theme.Spacing.cozy))
        }
        .padding(Theme.Spacing.inset)
        .background(Theme.Surface.background))
      host.frame = NSRect(origin: .zero, size: host.fittingSize)
      let window = Self.standaloneWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      window.orderFrontRegardless()
      try? await Task.sleep(for: .seconds(1))
      write(window, as: "speaker-menu", chrome: false)
      window.close()
    }

    /// The detail toolbar of a conversation memo (Copy is a menu: transcript and reply) and of a transcript memo (Copy is a button), light
    /// and dark, in a strip of ours on the window's own tint: no control may draw in the accent. The strip carries the controls
    /// of the real toolbar (``MacDetailToolbar``); the window's own toolbar comes out blank on a host with no display.
    private func writeToolbarStrips() async {
      let player = MacAudioPlayer()
      let memos: [(String, String)] = [("conversation", replyMemoID), ("transcript", SampleData.transcriptThreadID)]
      for (kind, id) in memos {
        let model = root.detailModel(for: id)
        await model.load()
        guard let memo = model.memo else { continue }
        let bar = MacDetailToolbar(root: root, model: model, player: player, memo: memo)
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
          let host = NSHostingView(
            rootView: HStack(spacing: Theme.Spacing.cozy) {
              HStack(spacing: Theme.Spacing.snug) { bar.primary }
              HStack(spacing: Theme.Spacing.snug) { bar.flags }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(Theme.Accent.fill)
            .padding(Theme.Spacing.inset)
            .background(Theme.Surface.background))
          host.appearance = NSAppearance(named: appearance)
          host.frame = NSRect(origin: .zero, size: host.fittingSize)
          let window = Self.standaloneWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: appearance)
          window.contentView = host
          window.orderFrontRegardless()
          try? await Task.sleep(for: .seconds(1))
          write(window, as: "window-toolbar-detail-\(kind)\(suffix)", chrome: false)
          window.close()
        }
      }
    }

    /// The transcript memo's pane alone in a window of ours, light and dark: the Transcript section with its Copy button.
    private func writeTranscriptPane() async {
      let player = MacAudioPlayer()
      let size = NSSize(width: 760, height: 520)
      for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        let host = NSHostingView(
          rootView: MacMemoDetailPane(
            root: root, model: root.detailModel(for: SampleData.transcriptThreadID), player: player
          )
          .tint(Theme.Accent.fill)
          .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = Self.standaloneWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        write(window, as: "window-transcript-pane\(suffix)", chrome: false)
        window.close()
      }
    }

    /// The sidebar alone in a window of ours: the main window's own picture comes out blank on a host whose window server has no
    /// display for it, and the sidebar is what the connection line and the Favorites count change.
    private func writeSidebar(as name: String, appearance: NSAppearance.Name = .aqua) async {
      let host = NSHostingView(
        rootView: MacSidebar(root: root).frame(width: 240, height: 420).background(Theme.Surface.background))
      host.frame = NSRect(x: 0, y: 0, width: 240, height: 420)
      host.appearance = NSAppearance(named: appearance)
      let window = Self.standaloneWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.title = "Iris sidebar snapshot"
      window.appearance = NSAppearance(named: appearance)
      window.contentView = host
      window.orderFrontRegardless()
      try? await Task.sleep(for: .seconds(1))
      write(window, as: name)
      window.close()
    }

    /// The sidebar, the list and the open conversation side by side in a window of ours, light and dark: the main window's own picture
    /// comes out blank on a host whose window server has no display, and this is what shows the three columns as one palette.
    private func writeShell() async {
      let player = MacAudioPlayer()
      let size = NSSize(width: Theme.Spacing.windowWidth, height: Theme.Spacing.windowHeight)
      for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        let host = NSHostingView(
          rootView: HStack(spacing: 0) {
            MacSidebar(root: root).frame(width: Theme.Spacing.windowSidebarIdeal)
            Theme.Surface.hairline.frame(width: 1)
            MacMemoList(root: root, model: root.windowHistory, player: player)
              .frame(width: Theme.Spacing.windowListIdeal)
            Theme.Surface.hairline.frame(width: 1)
            MacMemoDetailPane(root: root, model: root.detailModel(for: replyMemoID), player: player)
          }
          .tint(Theme.Accent.fill)
          .environment(\.replyImageStore, root.replyImages)
          .environment(\.artifactStore, root.artifacts)
          .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = Self.standaloneWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))
        write(window, as: "window-shell\(suffix)", chrome: false)
        window.close()
      }
    }

    /// The conversation pane alone, light and dark, with the whole reply of the first answer playing: every answer carries the inline
    /// player (round pause or play button, scrubber, time left, the form menu), the playing one part way through.
    private func writeConversationPlayer() async {
      guard let memo = try? await root.fakeAPI?.memo(id: threadMemoID).memo else { return }
      let size = NSSize(width: 560, height: 640)
      for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        let player = MacAudioPlayer()
        let host = NSHostingView(
          rootView: MacMemoDetailPane(root: root, model: root.detailModel(for: threadMemoID), player: player)
            .tint(Theme.Accent.fill)
            .environment(\.replyImageStore, root.replyImages)
            .environment(\.artifactStore, root.artifacts)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = Self.standaloneWindow(
          contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        // The whole reply is the longer silent clip, so it still plays when the picture is taken.
        player.start(memo.id, .reply(.full), request: root.mediaSource.speech(for: memo, variant: .full))
        try? await Task.sleep(for: .seconds(2))
        write(window, as: "window-conversation\(suffix)", chrome: false)
        player.stop()
        window.close()
      }
    }

    /// The main window's toolbar actions (New memo, Transcribe, and Stop while a take runs) hosted in a strip of ours, light and
    /// dark, and the sidebar with an active kind and state filter, light and dark. The window's own toolbar comes out blank on a
    /// host with no display.
    private func writeTranscribeAndFilter() async {
      for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        for recording in [false, true] {
          let host = NSHostingView(
            rootView: HStack(spacing: Theme.Spacing.cozy) {
              Button(
                String(localized: "New memo", comment: "Main window toolbar: opens the New memo page"),
                systemImage: "square.and.pencil"
              ) {}
              if recording {
                Button(String(localized: "Stop", comment: "Stops the take"), systemImage: "stop.fill") {}
              } else {
                MacTranscribeButton(root: root)
              }
            }
            .labelStyle(.titleAndIcon)
            .padding(Theme.Spacing.inset)
            .background(Theme.Surface.background))
          host.appearance = NSAppearance(named: appearance)
          host.frame = NSRect(origin: .zero, size: host.fittingSize)
          let window = Self.standaloneWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: appearance)
          window.contentView = host
          window.orderFrontRegardless()
          try? await Task.sleep(for: .seconds(1))
          write(window, as: "window-toolbar-\(recording ? "stop" : "transcribe")\(suffix)", chrome: false)
          window.close()
        }
      }
      if let kind = root.filterKinds.first {
        root.toggleKindFilter(kind)
        root.toggleStateFilter(.notified)
        try? await Task.sleep(for: .seconds(1))
        await writeSidebar(as: "sidebar-filtered", appearance: .aqua)
        await writeSidebar(as: "sidebar-filtered-dark", appearance: .darkAqua)
        write(windowTitled: Self.mainTitle, as: "window-filter-active")
        root.clearKindAndStateFilter()
      }
    }

    /// The open conversation's Details popover content (steps, copy rows, ids; Previous and Next between its answers), light and dark.
    /// The popover is a window of its own that the window server answers 2 x 1 pixels for, so its view is hosted in a window of
    /// ours and drawn from there.
    private func writeDetails(memoID: String, names: [(String, NSAppearance.Name)]) async {
      let model = root.detailModel(for: memoID)
      for (name, appearance) in names {
        let host = NSHostingView(
          rootView: MacMemoDetailsPopover(root: root, model: model).background(Theme.Surface.background))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = Self.standaloneWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: appearance)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        write(window, as: name, chrome: false)
        window.close()
      }
    }

    /// The New memo page, empty and with a draft; then the draft sent through the fake outbox: the new memo opens with its question
    /// and the pending answer, and a moment later with the fake answer.
    private func writeNewMemo() async {
      root.newMemo()
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-new")
      let composer = root.composer(for: nil)
      // l10n:ignore sample text typed into the field
      composer.text = "Draft a short status update for the Friday release."
      try? await Task.sleep(for: .seconds(1))
      write(windowTitled: Self.mainTitle, as: "window-composer")
      await root.sendTyped(composer, mode: .hermes)
      try? await Task.sleep(for: .seconds(1.6))
      write(windowTitled: Self.mainTitle, as: "window-sent")
      try? await Task.sleep(for: .seconds(2.4))
      write(windowTitled: Self.mainTitle, as: "window-answered")
    }

    /// The running turn of the open conversation as the event stream fills it: the tool Hermes started, then the text so far.
    private func writeStreaming(memoID: String) async {
      guard let fake = root.fakeAPI else { return }
      fake.emit(.memoActivity(MemoActivity(id: memoID, attempt: 1, tool: "web")))
      // l10n:ignore sample text of a streamed answer
      let pieces = [
        "The Friday release is on track. ", "Two reviews are still open and the migration ", "has run on staging.",
      ]
      for (offset, piece) in pieces.enumerated() {
        fake.emit(.memoDelta(MemoDelta(id: memoID, attempt: 1, seq: offset + 1, text: piece)))
      }
      try? await Task.sleep(for: .seconds(1.5))
      write(windowTitled: Self.mainTitle, as: "window-streaming")
    }

    /// A question typed into the popover's quick-ask line and sent: the answer streams in under the line. The fake pipeline holds
    /// the stream for a moment before the stored answer replaces it, so the picture is taken as soon as the text shows.
    private func writeQuickAsk() async {
      let composer = root.quickAskComposer
      // l10n:ignore sample text typed into the field
      composer.text = "Where do we stand on the Friday release?"
      await root.sendTyped(composer, mode: .hermes)
      for _ in 0..<300 where !isStreaming(root.quickAnswer) { try? await Task.sleep(for: .milliseconds(15)) }
      // The view catches up with the model on the next turn of the run loop.
      try? await Task.sleep(for: .milliseconds(60))
      write(windowTitled: Self.panelTitle, as: "menu-ask", chrome: false)
    }

    private func isStreaming(_ answer: MacMemoDetailModel?) -> Bool {
      answer?.turns.contains { if case .streaming = $0.content { true } else { false } } ?? false
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
      await writeSettingsWindowDark(as: "settings-connection-dark")
      root.settingsTab = .recording
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-recording")
      root.settingsTab = .general
      updateEngine?.status = .upToDate
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-general")
      updateEngine?.status = .available(version: "0.3.2", build: "820")
      try? await Task.sleep(for: .seconds(1))
      writeSettingsWindow(as: "settings-general-update")
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
      let window = Self.standaloneWindow(
        contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
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
    private func writeSettingsWindowDark(as name: String) async {
      guard let window = settingsWindow() else { return }
      await writeDark(window, as: name)
    }

    private func settingsWindow() -> NSWindow? {
      let titles = [
        String(localized: "Connection", comment: "Settings tab"),
        String(localized: "Recording", comment: "Settings tab"),
        String(localized: "General", comment: "Settings tab"),
      ]
      let window = NSApp.windows.first(where: { titles.contains($0.title) && $0.isVisible })
      if window == nil { Self.logger.error("no visible Settings window: \(describeWindows(), privacy: .public)") }
      return window
    }

    private func writeSettingsWindow(as name: String) {
      guard let window = settingsWindow() else { return }
      write(window, as: name)
    }

    /// The same window in the dark appearance (the system's stays as it was), after a moment for the views to redraw.
    private func writeDark(windowTitled title: String, as name: String, chrome: Bool = true) async {
      guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else { return }
      await writeDark(window, as: name, chrome: chrome)
    }

    private func writeDark(_ window: NSWindow, as name: String, chrome: Bool = true) async {
      let before = window.appearance
      window.appearance = NSAppearance(named: .darkAqua)
      try? await Task.sleep(for: .seconds(1))
      write(window, as: name, chrome: chrome)
      window.appearance = before
      try? await Task.sleep(for: .milliseconds(500))
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
    func write(_ window: NSWindow, as name: String, chrome: Bool = true) {
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

    /// A window of ours for a picture. It is not released when closed: under ARC the default (released on close) frees it a second time
    /// and the run dies with a segmentation fault in AppKit's window animation when the next one is made.
    private static func standaloneWindow(
      contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool
    ) -> NSWindow {
      let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
      window.isReleasedWhenClosed = false
      return window
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
