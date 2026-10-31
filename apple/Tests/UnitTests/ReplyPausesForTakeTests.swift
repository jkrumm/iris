import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// Wave 18 I1: recording takes priority over playback. `TakeController.captureActive` is set synchronously by a start (a
/// thread's hold-to-talk included) and cleared only once the session has ended; the player reads it right before anything
/// starts, and a take start drops a speech that is still downloading.
@MainActor
@Suite("A take start pauses playback")
struct ReplyPausesForTakeTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  private let memo = MemoFactory.memo("spoken", audioSeconds: 3, replyText: "ok")
  private let source = FakeMediaSource()

  /// Reads what the controller's flag was at the moment `isConfigured` (the first thing `begin` asks) ran.
  private final class FlagProbe {
    weak var controller: TakeController?
    var sawActive: Bool?
  }

  private func makeController(
    _ rig: OutboxRig, speech: SpeechPlayer, probe: FlagProbe? = nil, isConfigured: Bool = true
  ) -> TakeController {
    let coordinator = TakeLiveActivityCoordinator(
      activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created)
    let controller = TakeController(
      stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
      isConfigured: {
        probe?.sawActive = probe?.controller?.captureActive
        return isConfigured
      }, requestPermission: { true }, speech: speech)
    probe?.controller = controller
    speech.captureActive = { [weak controller] in controller?.captureActive ?? false }
    return controller
  }

  @Test("pauseForTake stops the reply and the open detail's recording, and keeps them stopped")
  func pausesBoth() async {
    let speech = SpeechPlayer()
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: speech)
    playback.attach()
    await playback.recording.load(source.audio(for: memo))

    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id))
    speech.pauseForTake()
    #expect(!speech.isPlaying(memo.id) && !speech.isBusy)

    playback.toggleRecording()
    #expect(playback.recording.isPlaying)
    speech.pauseForTake()
    #expect(!playback.recording.isPlaying && !speech.isBusy)
    playback.teardown()
  }

  @Test("a start sets the flag before it awaits anything, pauses the reply, and a failed start clears it again")
  func flagIsSetAtBegin() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let probe = FlagProbe()
    let controller = makeController(rig, speech: speech, probe: probe)
    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id) && !controller.captureActive)

    try await controller.start(mode: .auto)

    #expect(probe.sawActive == true, "set on entry to begin, before the permission or the session")
    #expect(controller.captureActive)
    #expect(!speech.isPlaying(memo.id), "paused, not released")
    #expect(speech.player.isLoaded)
    try await controller.stop()
    #expect(!controller.captureActive)
    #expect(!speech.isPlaying(memo.id), "ending the take does not resume it")

    let refused = makeController(OutboxRig(client: client), speech: SpeechPlayer(), isConfigured: false)
    await #expect(throws: StartMemoError.self) { try await refused.start(mode: .auto) }
    #expect(!refused.captureActive, "a start that never began leaves no claim")
  }

  @Test("the flag stays set while the recorder's stop has not returned, and clears when it has")
  func flagHeldAcrossAHungStop() async throws {
    let gate = StopGate()
    let rig = OutboxRig(client: client, recorder: { StopGatedRecorder(base: $0, gate: gate) })
    let speech = SpeechPlayer()
    let controller = makeController(rig, speech: speech)
    try await controller.start(mode: .auto)
    await rig.capture.recordWithoutClock(seconds: 12)

    let stopping = Task { try await controller.stop() }
    for _ in 0..<500 where await gate.arrived == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await gate.arrived > 0, "the stop is suspended inside the recorder")
    #expect(controller.captureActive, "a hung stop keeps the claim")
    #expect(await speech.play(memo, source: source) == false)

    await gate.open()
    _ = try await stopping.value
    #expect(!controller.captureActive)
  }

  @Test("while the flag is set no playback starts: Play, resuming, the recording's button; it works again after")
  func nothingStartsWhileSet() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = makeController(rig, speech: speech)
    let playback = MemoPlayback(memoID: memo.id, recordingDuration: 3, speech: speech)
    playback.attach()
    await playback.recording.load(source.audio(for: memo))

    try await controller.start(mode: .auto)
    // A Play that fetched its memo before the take reaches the player now.
    #expect(await speech.play(memo, source: source) == false)
    await speech.toggle(memo, source: source)
    playback.toggleRecording()
    #expect(!speech.isPlaying(memo.id) && !speech.player.isLoaded && !playback.recording.isPlaying)

    try await controller.stop()
    #expect(await speech.play(memo, source: source), "the take is over: playing is allowed again")
    playback.toggleRecording()
    #expect(playback.recording.isPlaying && !speech.isPlaying(memo.id))
    playback.teardown()
    speech.stop()
  }

  @Test("a thread's hold-to-talk claims the flag first thing, and releases it when the session has ended")
  func threadTakeClaims() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = makeController(rig, speech: speech)
    await speech.play(memo, source: source)
    #expect(speech.isPlaying(memo.id))

    let voice = rig.voice(
      claim: { controller.claimCapture() }, release: { await controller.releaseCapture($0) })
    try await voice.begin(VoiceReplyRequest(threadId: "thread-1", mode: .chat))

    #expect(controller.captureActive && !speech.isPlaying(memo.id))
    #expect(await speech.play(memo, source: source) == false)
    #expect(try await rig.stack.session().current.phase == .recording)
    _ = try await voice.end(cancelled: true)
    #expect(!controller.captureActive)
  }

  @Test("a thread take whose start is refused releases its claim")
  func refusedThreadTakeReleases() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = makeController(rig, speech: speech)
    let voice = OutboxVoiceReplyCapture(
      stack: rig.stack, service: rig.service,
      requestPermission: { false },
      claim: { controller.claimCapture() }, release: { await controller.releaseCapture($0) })

    await #expect(throws: CaptureError.self) {
      try await voice.begin(VoiceReplyRequest(threadId: "thread-1", mode: .chat))
    }
    #expect(!controller.captureActive, "the take never opened")
  }

  @Test("a take start drops a speech that is still downloading: it cannot attach afterwards")
  func pauseInvalidatesAPendingLoad() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlowSpeechStub.self]
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-pause-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let downloader = MediaDownloader(session: URLSession(configuration: configuration), directory: directory)
    let speech = SpeechPlayer(player: MemoPlayer(downloader: downloader))

    let starting = Task { await speech.play(memo, source: SlowSource()) }
    for _ in 0..<500 where !speech.player.isLoading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(speech.player.isLoading, "the download is on the wire")

    speech.pauseForTake()
    #expect(await starting.value == false)

    #expect(!speech.player.isLoaded && !speech.isPlaying(memo.id) && speech.memoID == nil)
  }

  @Test("a start with nothing playing changes nothing")
  func nothingPlaying() async throws {
    let rig = OutboxRig(client: client)
    let speech = SpeechPlayer()
    let controller = makeController(rig, speech: speech)

    try await controller.start(mode: .auto)

    #expect(!speech.isBusy && speech.memoID == nil)
    try await controller.stop()
  }
}

/// A speech route that answers after a delay, so a test can stop a download that is still on the wire.
private struct SlowSource: MemoMediaSource {
  func audio(for memo: Memo) -> MediaRequest? { nil }
  func speech(for memo: Memo) -> MediaRequest? {
    MediaRequest(url: URL(string: "https://slow.media.example.com/speech")!, headers: [:], cacheName: "slow.mp3")
  }
  func asset(memoID: String, assetID: String) -> MediaRequest? { nil }
}

private nonisolated final class SlowSpeechStub: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    else { return }
    nonisolated(unsafe) let this = self
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
      this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
      this.client?.urlProtocol(this, didLoad: Data("audio".utf8))
      this.client?.urlProtocolDidFinishLoading(this)
    }
  }
}

private actor StopGate {
  private(set) var arrived = 0
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func pass() async {
    arrived += 1
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }
}

/// A recorder whose `stop()` waits for the gate: a stop that hangs.
private nonisolated struct StopGatedRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder
  let gate: StopGate

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }

  func stop() async throws {
    await gate.pass()
    try await base.stop()
  }

  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}
