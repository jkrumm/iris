import Foundation
import Testing

@testable import IrisCore

@MainActor
@Suite("ReplyBarModel")
struct ReplyBarModelTests {
  private let start = ConversationFixtures.now
  private let notices = Notices()

  private func model(voice: any VoiceReplyCapture, clock: Clock) -> ReplyBarModel {
    let notices = notices
    return ReplyBarModel(voice: voice, now: { clock.now }, onNotice: { notices.list.append($0) })
  }

  // MARK: Draft

  @Test("a draft is sendable once it has more than whitespace; taking it trims and clears")
  func takeDraft() {
    let bar = model(voice: UnavailableVoiceReplyCapture(), clock: Clock(start))
    #expect(!bar.canSendDraft && bar.takeDraft() == nil)
    bar.draft = "  \n "
    #expect(!bar.canSendDraft && bar.takeDraft() == nil)

    bar.draft = "  hello there \n"
    #expect(bar.canSendDraft)
    #expect(bar.takeDraft() == "hello there")
    #expect(bar.draft.isEmpty && !bar.canSendDraft)
  }

  @Test("a restored text fills a blank draft and goes in front of a newer one")
  func restoreDraft() {
    let bar = model(voice: UnavailableVoiceReplyCapture(), clock: Clock(start))
    bar.restoreDraft("first")
    #expect(bar.draft == "first")

    bar.draft = "newer"
    bar.restoreDraft("older")
    #expect(bar.draft == "older\nnewer")
  }

  // MARK: Voice

  @Test("a voice reply is a capture request bound to the thread, and the take becomes the memo")
  func voiceReply() async throws {
    let sent = ConversationFixtures.memo("v", state: .receiving, threadId: "t")
    let voice = ScriptedVoice(outcome: .sent(sent))
    let clock = Clock(start)
    let bar = model(voice: voice, clock: clock)

    bar.beginVoice(threadID: "t")
    #expect(bar.voiceStartedAt == start)
    clock.now = start.addingTimeInterval(3)
    let memo = try #require(await bar.endVoice(cancelled: false))

    #expect(memo == sent)
    #expect(voice.requests == [VoiceReplyRequest(threadId: "t", mode: .hermes)])
    #expect(bar.voiceStartedAt == nil && notices.list.isEmpty)
  }

  @Test("a new hold waits while the last take is still being stopped and sent")
  func holdDuringSend() async {
    let voice = GatedVoice()
    let clock = Clock(start)
    let bar = model(voice: voice, clock: clock)

    bar.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    let ending = Task { await bar.endVoice(cancelled: false) }
    await voice.waitUntilEnding()
    #expect(!bar.isVoiceAvailable)
    bar.beginVoice(threadID: "t")
    #expect(bar.voiceStartedAt == nil)
    #expect(voice.begins == 1)

    voice.finish()
    _ = await ending.value
    #expect(bar.isVoiceAvailable)
    bar.beginVoice(threadID: "t")
    #expect(bar.voiceStartedAt != nil)
  }

  @Test("a release and a cancel arriving together end the take once")
  func endTwice() async {
    let voice = GatedVoice()
    let clock = Clock(start)
    let bar = model(voice: voice, clock: clock)

    bar.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    let release = Task { await bar.endVoice(cancelled: false) }
    await voice.waitUntilEnding()
    #expect(await bar.endVoice(cancelled: true) == nil)
    voice.finish()
    _ = await release.value
    #expect(voice.ends == 1)
  }

  @Test("a take the recorder lost is told to the user, not dropped quietly")
  func lostRecording() async {
    let clock = Clock(start)
    let bar = model(voice: ScriptedVoice(outcome: .recordingFailed), clock: clock)

    bar.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    #expect(await bar.endVoice(cancelled: false) == nil)
    #expect(notices.list == [.recordingFailed])
  }

  @Test("a take kept in the outbox is told as queued")
  func queued() async {
    let clock = Clock(start)
    let bar = model(voice: ScriptedVoice(outcome: .queued), clock: clock)

    bar.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    #expect(await bar.endVoice(cancelled: false) == nil)
    #expect(notices.list == [.queued])
  }

  @Test("a capture that cannot start or end reports a notice and leaves the bar idle")
  func failures() async {
    let clock = Clock(start)
    let cannotStart = model(voice: ScriptedVoice(beginFails: true), clock: clock)
    cannotStart.beginVoice(threadID: "t")
    #expect(await cannotStart.endVoice(cancelled: false) == nil)
    #expect(cannotStart.voiceStartedAt == nil)
    #expect(notices.list == [.couldNotStartRecording])

    let cannotEnd = model(voice: ScriptedVoice(endFails: true), clock: clock)
    cannotEnd.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    #expect(await cannotEnd.endVoice(cancelled: false) == nil)
    #expect(notices.list == [.couldNotStartRecording, .voiceFailed])
  }

  @Test("a cancelled take sends nothing and says nothing")
  func cancelled() async {
    let voice = ScriptedVoice(outcome: .sent(ConversationFixtures.memo("v")))
    let clock = Clock(start)
    let bar = model(voice: voice, clock: clock)

    bar.beginVoice(threadID: "t")
    clock.now = start.addingTimeInterval(3)
    #expect(await bar.endVoice(cancelled: true) == nil)
    #expect(voice.cancelledEnds == [true])
    #expect(bar.voiceStartedAt == nil && notices.list.isEmpty)
  }

  @Test("a touch shorter than the minimum take is a cancel with a hint")
  func tooShort() async {
    let voice = ScriptedVoice(outcome: .sent(ConversationFixtures.memo("v")))
    let bar = model(voice: voice, clock: Clock(start))

    bar.beginVoice(threadID: "t")
    #expect(await bar.endVoice(cancelled: false) == nil)
    #expect(voice.cancelledEnds == [true], "the capture is told to discard it")
    #expect(notices.list == [.tooShort])
  }

  @Test("without capture the control is unavailable and a hold does nothing")
  func voiceUnavailable() async {
    let bar = model(voice: UnavailableVoiceReplyCapture(), clock: Clock(start))
    #expect(!bar.isVoiceAvailable)
    bar.beginVoice(threadID: "t")
    #expect(bar.voiceStartedAt == nil)
    #expect(await bar.endVoice(cancelled: false) == nil)
  }
}

@MainActor
private final class Notices {
  var list: [ReplyBarModel.Notice] = []
}

/// A clock the test moves by hand.
@MainActor
private final class Clock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

private struct VoiceError: Error {}

/// A capture that answers as scripted and remembers what it was asked.
@MainActor
private final class ScriptedVoice: VoiceReplyCapture {
  private let outcome: VoiceReplyOutcome
  private let beginFails: Bool
  private let endFails: Bool
  private(set) var requests: [VoiceReplyRequest] = []
  private(set) var cancelledEnds: [Bool] = []

  init(outcome: VoiceReplyOutcome = .discarded, beginFails: Bool = false, endFails: Bool = false) {
    self.outcome = outcome
    self.beginFails = beginFails
    self.endFails = endFails
  }

  var isAvailable: Bool { true }

  func begin(_ request: VoiceReplyRequest) async throws {
    requests.append(request)
    if beginFails { throw VoiceError() }
  }

  func end(cancelled: Bool) async throws -> VoiceReplyOutcome {
    cancelledEnds.append(cancelled)
    if endFails { throw VoiceError() }
    return cancelled ? .discarded : outcome
  }
}

/// A capture whose `end` waits for the test, to hold a take in the middle of being sent.
@MainActor
private final class GatedVoice: VoiceReplyCapture {
  private(set) var begins = 0
  private(set) var ends = 0
  private let ending: AsyncStream<Void>
  private let endingSignal: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>
  private let releaseSignal: AsyncStream<Void>.Continuation

  init() {
    (ending, endingSignal) = AsyncStream.makeStream()
    (release, releaseSignal) = AsyncStream.makeStream()
  }

  var isAvailable: Bool { true }

  func begin(_ request: VoiceReplyRequest) async throws { begins += 1 }

  func end(cancelled: Bool) async throws -> VoiceReplyOutcome {
    ends += 1
    endingSignal.yield()
    for await _ in release { break }
    return .discarded
  }

  /// Waits for `end` to be called, but never forever: past `seconds` the test fails instead of hanging.
  func waitUntilEnding(seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async {
    let ending = ending
    let arrived = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in ending { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(seconds))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !arrived { Issue.record("end was not called within \(seconds) s", sourceLocation: sourceLocation) }
  }

  func finish() { releaseSignal.yield() }
}
