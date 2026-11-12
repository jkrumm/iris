import AppKit
import CoreServices
import Foundation
import IrisCore
import IrisUI
import SwiftUI
import Testing

@testable import IrisMac

@MainActor
@Suite("Mac conversation")
struct MacConversationTests {
  /// A fake root whose pipeline takes 200 ms per stage (the reply streams in the last 30 ms of the first), loaded.
  private func loadedRoot(
    hotkey: FakeTakeHotkey = FakeTakeHotkey(), engine: FakeTakeEngine = FakeTakeEngine()
  ) async -> MacCompositionRoot {
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument, "-IrisFakeStepMs", "200"],
      credentials: InMemoryCredentialStore(), poster: RecordingNotificationPoster(), takeEngine: engine,
      permission: FakeMicrophonePermission(), hotkey: hotkey)
    root.begin()
    _ = await eventually { !root.windowHistory.memos.isEmpty || !root.history.memos.isEmpty }
    return root
  }

  private func isStreaming(_ model: MacMemoDetailModel?) -> String? {
    for turn in model?.turns ?? [] {
      if case .streaming(let markdown, _) = turn.content { return markdown }
    }
    return nil
  }

  // MARK: Popover

  @Test("a popover send creates a memo and shows the streamed answer in the popover, not in the window")
  func popoverSend() async throws {
    let root = await loadedRoot()
    let composer = root.quickAskComposer
    #expect(composer !== root.composer(for: nil), "the popover's draft is its own")
    composer.text = "Where do we stand?"
    await root.sendTyped(composer, mode: .hermes)

    #expect(composer.text.isEmpty && composer.failure == nil)
    let requests = await root.fakeAPI?.calls.compactMap { (call) -> CreateTextMemoRequest? in
      guard case .createTextMemo(let request) = call else { return nil }
      return request
    }
    let created = try #require(requests?.first)
    #expect(requests?.count == 1 && created.text == "Where do we stand?" && created.mode == .hermes)
    let answer = try #require(root.quickAnswer, "the answer opens in the popover")
    #expect(answer.memoID == created.id && root.selectedMemoID == nil, "the window's selection is left alone")
    #expect(answer.turns.first?.content == .user("Where do we stand?"))

    #expect(await eventually { isStreaming(answer) != nil })
    #expect(isStreaming(answer) == "This is the fake answer to your message.")
  }

  @Test("Open in window shows the quick answer's memo in the main window and clears the popover")
  func openInWindow() async throws {
    let root = await loadedRoot()
    let composer = root.quickAskComposer
    composer.text = "Continue this in the window"
    await root.sendTyped(composer, mode: .hermes)
    let id = try #require(root.quickAnswer?.memoID)
    let before = root.windowRequest
    root.openQuickAnswerInWindow()
    #expect(root.selectedMemoID == id && root.quickAnswer == nil && root.windowRequest == before + 1)
  }

  @Test("Done dismisses the quick answer")
  func dismiss() async {
    let root = await loadedRoot()
    let composer = root.quickAskComposer
    composer.text = "Something short"
    await root.sendTyped(composer, mode: .hermes)
    #expect(root.quickAnswer != nil)
    root.dismissQuickAnswer()
    #expect(root.quickAnswer == nil)
  }

  // MARK: Streaming in the window's detail model

  @Test("a running turn becomes the tool list, then the streaming answer with the id of the final reply")
  func detailStreams() async throws {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let id = SampleData.hermesFollowUpID
    let model = MacMemoDetailModel(memoID: id, client: api, pasteboard: MacPasteboard())
    await model.load()
    #expect(model.turns.last.map { if case .pending = $0.content { true } else { false } } == true)

    await model.apply(.memoActivity(MemoActivity(id: id, attempt: 1, tool: "web")))
    guard case .working(let lines)? = model.turns.last?.content else {
      Issue.record("a tool started but the turn is not the working list")
      return
    }
    #expect(lines.map(\.label) == [ToolActivityText.label(for: "web")])

    await model.apply(.memoDelta(MemoDelta(id: id, attempt: 1, seq: 1, text: "So far")))
    await model.apply(.memoDelta(MemoDelta(id: id, attempt: 1, seq: 2, text: " more")))
    #expect(
      model.turns.last?.content
        == .streaming(markdown: "So far more", activity: ToolActivityText.label(for: "web")))
    #expect(model.turns.last?.id == "\(id).reply")

    await model.apply(.memoDelta(MemoDelta(id: "someone-else", attempt: 1, seq: 1, text: "not mine")))
    #expect(isStreaming(model) == "So far more", "an event of another conversation changes nothing")
  }

  // MARK: Voice

  @Test("a spoken reply in a conversation carries the thread id; a new memo carries none")
  func voiceReplyCarriesThread() async throws {
    let engine = FakeTakeEngine()
    let root = await loadedRoot(engine: engine)
    root.talk(in: SampleData.hermesThreadID)
    await root.recording.settled()
    #expect(root.recording.isRecording && engine.startedThreadIDs == [SampleData.hermesThreadID])
    root.recording.stop()
    await root.recording.settled()
    root.talk(in: nil)
    await root.recording.settled()
    #expect(engine.startedThreadIDs == [SampleData.hermesThreadID, nil])
    root.recording.cancel()
    await root.recording.settled()
  }

  @Test("the global key continues the conversation in front in the main window, and starts a new memo otherwise")
  func hotkeyContinuesFrontConversation() async throws {
    let hotkey = FakeTakeHotkey()
    let engine = FakeTakeEngine()
    let root = await loadedRoot(hotkey: hotkey, engine: engine)
    root.installHotkey()
    root.selectedMemoID = SampleData.hermesThreadID
    let open = root.detailModel(for: SampleData.hermesThreadID)
    await open.load()
    let threadID = try #require(open.replyThreadID)

    #expect(root.frontConversationThreadID == nil, "a window that is not in front continues nothing")
    root.isMainWindowFront = true
    #expect(root.frontConversationThreadID == threadID)

    hotkey.press()
    #expect(await eventually { root.recording.isRecording })
    #expect(engine.startedThreadIDs == [threadID])
    hotkey.press()
    #expect(await eventually { root.recording.phase == .idle })

    root.selectedMemoID = nil
    #expect(root.frontConversationThreadID == nil, "the New memo page has no conversation")
    hotkey.press()
    #expect(await eventually { root.recording.isRecording })
    #expect(engine.startedThreadIDs == [threadID, nil])
    root.recording.cancel()
    await root.recording.settled()
  }

  // MARK: Keyboard

  @Test("Shift-Return puts the line break at the caret, replaces a selection, and falls back to the end")
  func shiftReturnAtCaret() {
    let text = "Hello world"
    let caret = text.index(text.startIndex, offsetBy: 5)
    let inserted = PromptCaret.insertingNewline(into: text, selection: TextSelection(insertionPoint: caret))
    #expect(inserted.text == "Hello\n world")
    if case .selection(let range)? = inserted.selection?.indices {
      #expect(
        inserted.text.distance(from: inserted.text.startIndex, to: range.lowerBound) == 6, "the caret follows the break"
      )
      #expect(range.isEmpty)
    } else {
      Issue.record("no caret after the break")
    }

    let word = text.index(text.startIndex, offsetBy: 5)..<text.index(text.startIndex, offsetBy: 6)
    #expect(
      PromptCaret.insertingNewline(into: text, selection: TextSelection(range: word)).text == "Hello\nworld",
      "a selected range is replaced")

    #expect(PromptCaret.insertingNewline(into: text, selection: nil).text == "Hello world\n")
    let stale = "A much longer text".endIndex
    #expect(
      PromptCaret.insertingNewline(into: "short", selection: TextSelection(insertionPoint: stale)).text
        == "short\n", "a caret from an older, longer string goes to the end")
  }

  @Test("a caret at the very start and end of the text")
  func caretAtEdges() {
    let start = PromptCaret.insertingNewline(into: "abc", selection: TextSelection(insertionPoint: "abc".startIndex))
    #expect(start.text == "\nabc")
    let end = PromptCaret.insertingNewline(into: "abc", selection: TextSelection(insertionPoint: "abc".endIndex))
    #expect(end.text == "abc\n")
  }

  // MARK: Launch

  @Test(
    "a launch by the user opens the main window once; a launch at login, a first run and the fake composition do not")
  func launchOpensWindow() {
    let user = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster())
    #expect(!user.launchWindowPending)
    user.launchDidFinish(loginItem: false)
    #expect(user.launchWindowPending)
    #expect(user.takeLaunchWindow() && !user.takeLaunchWindow(), "the label takes it once")

    user.launchDidFinish(loginItem: true)
    #expect(!user.launchWindowPending)

    let firstRun = MacCompositionRoot(
      arguments: [], credentials: InMemoryCredentialStore(), poster: RecordingNotificationPoster(),
      takeEngine: FakeTakeEngine(), permission: FakeMicrophonePermission(), hotkey: FakeTakeHotkey())
    #expect(firstRun.needsOnboarding)
    firstRun.launchDidFinish(loginItem: false)
    #expect(!firstRun.launchWindowPending, "the onboarding window opens instead")
  }

  @Test("the system's open event says whether a login item started the app")
  func loginItemEvent() {
    func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
      let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
      if loginItem {
        event.setParam(
          NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
      }
      return event
    }
    #expect(MacLaunchOrigin.isLoginItem(openEvent(loginItem: true)))
    #expect(!MacLaunchOrigin.isLoginItem(openEvent(loginItem: false)))
    #expect(!MacLaunchOrigin.isLoginItem(nil))
  }
}
