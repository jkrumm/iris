import Foundation
import Testing

@testable import IrisCapture

struct FakeCaptureTests {
  /// Pipes recorder events into the outbox, like the app's capture coordinator does.
  private func pump(_ recorder: any SegmentRecorder, into outbox: any SegmentOutbox) -> Task<[ClosedSegment], Never> {
    let events = recorder.events
    return Task {
      var closed: [ClosedSegment] = []
      for await event in events {
        switch event {
        case .segmentClosed(let segment, _):
          closed.append(segment)
          await outbox.enqueue(segment)
        case .stopped(let memoID, let segmentCount):
          await outbox.finishMemo(memoID, segmentCount: segmentCount)
          return closed
        case .started, .failed:
          continue
        }
      }
      return closed
    }
  }

  @Test func scriptedTakeFlowsThroughRotationAndOutboxToCompletion() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness(deletesFilesWhenDone: false)
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let collector = pump(fake.recorder, into: harness.outbox)
    let id = try await fake.startTake()
    await fake.record(seconds: 4)
    try await fake.switchInput(to: FakeRouteManager.headsetMic.uid)  // seg 0: 4 s, mic switch
    await fake.record(seconds: 12)  // seg 1: 10 s at the boundary, 2 s open
    await fake.interrupt()  // seg 2: 2 s, interruption
    await fake.record(seconds: 3)  // paused: dropped
    await fake.endInterruption()
    await fake.record(seconds: 5)
    await fake.engineConfigurationChanged()  // seg 3: 5 s, configuration change
    await fake.record(seconds: 1)
    try await fake.stopTake()  // seg 4: 1 s, stop flush

    let closed = await collector.value
    #expect(closed.map(\.index) == [0, 1, 2, 3, 4])
    #expect(closed.map(\.duration) == [4, 10, 2, 5, 1])
    #expect(closed.allSatisfy { $0.memoID == id })

    for segment in closed {
      let size = try FileManager.default.attributesOfItem(atPath: segment.fileURL.path)[.size] as? Int
      #expect(size == segment.byteCount)
      #expect(
        segment.byteCount == FakeSegmentRecorder.headerLength + Int(segment.duration)
          * FakeSegmentRecorder.bytesPerSecond)
    }

    await harness.outbox.settled()
    let uploaded = await harness.uploader.uploaded
    #expect(uploaded == (0..<5).map { SegmentKey(memoID: id, index: $0) })
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 5)])
    #expect(await harness.uploader.log.last == "complete")
    await harness.outbox.shutdown()
  }

  @Test func closeReasonsFollowTheScript() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = FakeCapture(directory: directory)
    let events = fake.recorder.events

    _ = try await fake.startTake()
    await fake.record(seconds: 1)
    try await fake.switchInput(to: FakeRouteManager.headsetMic.uid)
    await fake.record(seconds: 1)
    await fake.interrupt()
    await fake.endInterruption()
    await fake.record(seconds: 1)
    await fake.engineConfigurationChanged()
    await fake.record(seconds: 10.5)
    try await fake.stopTake()

    var reasons: [RotationReason] = []
    for await event in events {
      if case .segmentClosed(_, let reason) = event { reasons.append(reason) }
      if case .stopped = event { break }
    }
    #expect(reasons == [.micSwitch, .interruption, .configurationChange, .duration, .stop])
  }

  @Test func aTakeWithoutAudioEmitsNoSegmentAndStopsCleanly() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = FakeCapture(directory: directory)
    let events = fake.recorder.events

    let id = try await fake.startTake()
    try await fake.stopTake()

    var received: [CaptureEvent] = []
    for await event in events {
      received.append(event)
      if case .stopped = event { break }
    }
    #expect(received == [.started(id), .stopped(id, segmentCount: 0)])
  }

  @Test func recorderRejectsDoubleStartAndStopWithoutStart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = FakeCapture(directory: directory)

    await #expect(throws: CaptureError.notRecording) { try await fake.stopTake() }
    _ = try await fake.startTake()
    await #expect(throws: CaptureError.alreadyRecording) { try await fake.recorder.start(memoID: MemoID()) }
  }

  @Test func switchingInputPublishesARouteChangeAndRejectsUnknownPorts() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = FakeCapture(directory: directory)
    var changes = fake.routes.routeChanges.makeAsyncIterator()

    _ = try await fake.startTake()
    try await fake.switchInput(to: FakeRouteManager.headsetMic.uid)
    let change = await changes.next()
    #expect(change?.reason == .userSelection)
    #expect(change?.snapshot.currentInput == FakeRouteManager.headsetMic)

    await #expect(throws: CaptureError.inputUnavailable(uid: "nope")) {
      try await fake.routes.setPreferredInput(uid: "nope")
    }
  }

  @Test func interruptionsReachTheSessionStream() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = FakeCapture(directory: directory)
    var interruptions = fake.session.interruptions.makeAsyncIterator()

    _ = try await fake.startTake()
    await fake.interrupt()
    await fake.endInterruption(shouldResume: false)
    #expect(await interruptions.next() == .began)
    #expect(await interruptions.next() == .ended(shouldResume: false))
    #expect(await fake.session.isActive)
  }

  @Test func routeRulesAreKeyedByFingerprint() async {
    let routes = FakeRouteManager(outputUIDs: ["car", "speaker"])
    let fingerprint = await routes.currentRoute().fingerprint
    #expect(fingerprint == "car+speaker")
    await routes.setRule(fingerprint: fingerprint, preferredPortUID: FakeRouteManager.builtInMic.uid)
    #expect(await routes.rules() == [fingerprint: FakeRouteManager.builtInMic.uid])
    await routes.setRule(fingerprint: fingerprint, preferredPortUID: nil)
    #expect(await routes.rules()[fingerprint] == nil)
  }

  @Test func launchArgumentSelectsFakeCapture() {
    #expect(FakeCapture.isRequested(arguments: ["Iris", "-IrisFakeCapture"]))
    #expect(!FakeCapture.isRequested(arguments: ["Iris"]))
  }
}
