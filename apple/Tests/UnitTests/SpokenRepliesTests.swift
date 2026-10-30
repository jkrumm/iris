import Foundation
import IrisCore
import Synchronization
import Testing

@testable import Iris

/// A media source that has no speech the first time it is asked and the fake's after that.
private final class SilentSource: @unchecked Sendable {
  nonisolated(unsafe) static let shared = SilentSource()
  private var asked = 0

  func next() -> any MemoMediaSource {
    asked += 1
    return asked == 1 ? UnavailableMediaSource() : FakeMediaSource()
  }
}

/// The take activity the test drives, readable from the download's thread.
private nonisolated final class TakeProbe: Sendable {
  private let value = Mutex(TakeActivity())
  var activity: TakeActivity { value.withLock { $0 } }
  func update(_ change: (inout TakeActivity) -> Void) { value.withLock { change(&$0) } }
}

/// A speech route on a stub host. The stub runs `onRequest` when the download starts, then answers with `clip`: the test
/// changes the world while the download is pending.
private nonisolated final class SlowSpeechStub: URLProtocol {
  nonisolated(unsafe) static var onRequest: @Sendable () -> Void = {}
  nonisolated(unsafe) static var clip = Data()

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "speech.stub.example.com" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    Self.onRequest()
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.clip)
    client?.urlProtocolDidFinishLoading(self)
  }
}

private struct StubSpeechSource: MemoMediaSource {
  func audio(for memo: Memo) -> MediaRequest? { nil }
  func speech(for memo: Memo) -> MediaRequest? {
    guard memo.isSpeakable, let url = URL(string: "https://speech.stub.example.com/\(memo.id)") else { return nil }
    return MediaRequest(url: url, headers: [:], cacheName: "\(memo.id).speech.m4a")
  }
  func asset(memoID: String, assetID: String) -> MediaRequest? { nil }
}

@MainActor
@Suite("SpokenReplies", .serialized)
struct SpokenRepliesTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let speech = SpeechPlayer()

  private func replies(
    on: Bool = true, store: InMemorySpokenRepliesStore? = nil,
    createdHere: @escaping (String) async -> Bool = { _ in true },
    takes: @escaping () -> TakeActivity = { TakeActivity() }
  ) -> SpokenReplies {
    SpokenReplies(
      store: store ?? InMemorySpokenRepliesStore(on), speech: speech, client: client, media: { FakeMediaSource() },
      createdHere: createdHere, takes: takes)
  }

  private func seed(_ id: String = "m", state: MemoState = .notified, replyText: String? = "Alles notiert.") async {
    await client.seed(MemoFactory.detail(MemoFactory.memo(id, state: state, route: "hermes", replyText: replyText)))
  }

  @Test("a finished reply of this device is spoken while the app is in the foreground")
  func speaks() async {
    await seed()
    await replies().memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }

  @Test("it stays silent when the setting is off")
  func off() async {
    await seed()
    await replies(on: false).memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("it stays silent while the app is not in the foreground")
  func background() async {
    await seed()
    let replies = replies()
    replies.isForeground = false
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("another device's memo is never spoken")
  func otherDevice() async {
    await seed()
    await replies(createdHere: { _ in false }).memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("a memo that is parked or has no reply is not spoken")
  func notReady() async {
    await seed("parked", state: .needsRoute, replyText: nil)
    await seed("mute", replyText: nil)
    let replies = replies()
    await replies.memoDone(id: "parked")
    await replies.memoDone(id: "mute")
    #expect(speech.memoID == nil)
  }

  @Test("a reply that could not start is tried again on the next memo.done")
  func notMarkedUntilItPlays() async {
    await seed()
    // Another reply is loading: the player takes none. Simulated by a source without speech for the first attempt.
    let replies = SpokenReplies(
      store: InMemorySpokenRepliesStore(true), speech: speech, client: client,
      media: { SilentSource.shared.next() }, createdHere: { _ in true }, takes: { TakeActivity() })
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
    await replies.memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }

  @Test("each memo is spoken once")
  func once() async {
    await seed()
    let replies = replies()
    await replies.memoDone(id: "m")
    speech.stop()
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("the setting is read from the store and written back on change")
  func persists() {
    let store = InMemorySpokenRepliesStore(false)
    let replies = replies(on: false, store: store)
    #expect(!replies.isOn)
    replies.isOn = true
    #expect(store.load())
    #expect(self.replies(store: store).isOn)
  }

  // MARK: Busy: a spoken reply waits, never interrupts

  @Test("a reply that is playing is not interrupted, and the newcomer is never spoken later")
  func playingReplyIsNotInterrupted() async {
    await seed("playing")
    await seed("newcomer")
    let replies = replies()
    await replies.memoDone(id: "playing")
    #expect(speech.isPlaying("playing"))
    await replies.memoDone(id: "newcomer")
    #expect(speech.isPlaying("playing"))
    #expect(speech.memoID == "playing")
    // Skipped for good: neither a repeated `memo.done` nor the player going quiet speaks it.
    speech.pause()
    await replies.memoDone(id: "newcomer")
    #expect(speech.memoID == "playing" && !speech.isPlaying("newcomer"))
    speech.stop()
  }

  @Test("a take that records blocks the spoken reply and is left alone")
  func recordingTake() async {
    await seed()
    var recording = true
    let replies = replies(takes: { TakeActivity(isOpen: recording) })
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil && !speech.player.isLoaded)
    // Not queued: once the take is over the same memo still does not speak.
    recording = false
    await replies.memoDone(id: "m")
    #expect(speech.memoID == nil)
  }

  @Test("a take that opened and closed after the event, before the reply task ran, still blocks the reply")
  func takeBetweenEventAndTask() async {
    await seed()
    var activity = TakeActivity()
    let replies = replies(takes: { activity })
    let sampled = replies.consumeSample(id: "m")
    // The take opens and closes while `memoDone` waits for its task: only the counter shows it.
    activity = TakeActivity(isOpen: false, started: 1)
    await replies.memoDone(id: "m", takes: sampled)
    #expect(speech.memoID == nil)
  }

  @Test("a take open at the event that closed before the reply task ran still blocks the reply")
  func takeOpenAtTheEvent() async {
    await seed()
    let replies = replies()
    await replies.memoDone(id: "m", takes: TakeActivity(isOpen: true, started: 0))
    #expect(speech.memoID == nil)
  }

  @Test(
    "a take that opened and closed between the update and the done event, behind the refresh, still blocks the reply")
  func takeBehindTheRefresh() async {
    await seed()
    var activity = TakeActivity()
    let replies = replies(takes: { activity })
    replies.memoUpdated(id: "m")
    activity = TakeActivity(isOpen: false, started: 1)
    // The done event's own sample is taken after the take is over: only the update's sample shows it.
    await replies.memoDone(id: "m", takes: replies.consumeSample(id: "m"))
    #expect(speech.memoID == nil)
  }

  @Test("the open detail's recording keeps playing and the reply is skipped")
  func recordingPlayback() async {
    await seed()
    var paused = 0
    let owner = NSObject()
    speech.bindRecording(owner: owner, isPlaying: { true }, pause: { paused += 1 })
    await replies().memoDone(id: "m")
    #expect(paused == 0)
    #expect(speech.memoID == nil)
    speech.unbindRecording(owner: owner)
  }

  /// A speech player that downloads through the stub, with `probe` changed by the stub once the request is on the wire.
  private func downloading(_ probe: TakeProbe, whileRequestIsPending change: @escaping @Sendable (TakeProbe) -> Void)
    throws -> (SpokenReplies, SpeechPlayer, cleanup: () -> Void)
  {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-spoken-\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlowSpeechStub.self]
    let downloader = MediaDownloader(session: URLSession(configuration: configuration), directory: directory)
    let player = SpeechPlayer(player: MemoPlayer(downloader: downloader))
    let fake = FakeMediaSource()
    let memo = MemoFactory.memo("m", state: .notified, route: "hermes", replyText: "Alles notiert.")
    SlowSpeechStub.clip = try Data(contentsOf: #require(fake.speech(for: memo)?.url))
    SlowSpeechStub.onRequest = { change(probe) }
    let replies = SpokenReplies(
      store: InMemorySpokenRepliesStore(true), speech: player, client: client, media: { StubSpeechSource() },
      createdHere: { _ in true }, takes: { probe.activity })
    return (replies, player, { try? FileManager.default.removeItem(at: directory) })
  }

  @Test("a take that opens and closes while the speech downloads cancels the reply, now and for good")
  func takeOpensAndClosesMidDownload() async throws {
    await seed()
    let probe = TakeProbe()
    let (replies, player, cleanup) = try downloading(probe) { probe in
      probe.update { $0.started += 1 }  // a take opened ...
      probe.update { $0.isOpen = false }  // ... and was over before the speech arrived
    }
    defer { cleanup() }
    await replies.memoDone(id: "m")
    #expect(!player.isPlaying("m"))
    await replies.memoDone(id: "m")
    #expect(!player.isPlaying("m"), "skipped for good: nothing plays on a later memo.done either")
  }

  @Test("a take that is still open when the speech has downloaded cancels the reply")
  func takeOpenMidDownload() async throws {
    await seed()
    let probe = TakeProbe()
    let (replies, player, cleanup) = try downloading(probe) { probe in
      probe.update {
        $0.started += 1
        $0.isOpen = true
      }
    }
    defer { cleanup() }
    await replies.memoDone(id: "m")
    #expect(!player.isPlaying("m"))
    probe.update { $0.isOpen = false }
    await replies.memoDone(id: "m")
    #expect(!player.isPlaying("m"))
  }

  @Test("with no take around, the same download plays")
  func downloadPlays() async throws {
    await seed()
    let (replies, player, cleanup) = try downloading(TakeProbe()) { _ in }
    defer { cleanup() }
    await replies.memoDone(id: "m")
    #expect(player.isPlaying("m"))
    player.stop()
  }

  @Test("idle: nothing plays and no take records, so the reply speaks as before")
  func idleSpeaks() async {
    await seed()
    await replies().memoDone(id: "m")
    #expect(speech.isPlaying("m"))
    speech.stop()
  }
}
