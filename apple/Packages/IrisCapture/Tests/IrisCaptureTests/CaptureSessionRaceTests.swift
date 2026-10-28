import Foundation
import Testing

@testable import IrisCapture

/// A one-shot latch: `wait()` suspends until `open()`, whenever either happens.
private actor Latch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var arrivals = 0
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  /// Parks the caller until `open()`; records that it arrived.
  func wait() async {
    arrivals += 1
    for waiter in arrivalWaiters { waiter.resume() }
    arrivalWaiters = []
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitForArrival() async {
    guard arrivals == 0 else { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }
}

/// A session controller whose `configure()` waits for the test, to hold `start` in the middle.
private struct BlockingSession: AudioSessionController {
  let base: FakeAudioSessionController
  let latch: Latch

  var interruptions: AsyncStream<InterruptionEvent> { base.interruptions }

  func configure() async throws {
    await latch.wait()
    await base.configure()
  }

  func activate() async throws { await base.activate() }
  func deactivate() async throws { await base.deactivate() }
}

/// A clock whose first `now()` waits for the test, to hold a `start` before it has claimed anything.
private struct BlockingClock: CaptureClock {
  let base: ManualClock
  let latch: Latch

  func now() async -> Date {
    await latch.wait()
    return await base.now()
  }

  func sleep(until deadline: Date) async throws { try await base.sleep(until: deadline) }
}

/// A recorder whose `stop()` returns at once (and again, without throwing) but whose `.stopped` event only comes when the
/// test calls `finishStop()`: the recorder's own drain is still running while the session is `.stopping`.
private struct DeferredStopRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws {}
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }

  func finishStop() async throws { try await base.stop() }
}

struct CaptureSessionRaceTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  /// Races `work` against a deadline so a lost wake-up fails the test instead of hanging it. Unlike a task group it does
  /// not wait for `work` once the deadline passed: a hung worker is abandoned.
  private func within<T: Sendable>(
    _ seconds: Double, _ work: @escaping @Sendable () async -> T
  ) async -> T? {
    let (stream, continuation) = AsyncStream.makeStream(of: T?.self)
    let worker = Task { continuation.yield(await work()) }
    let timer = Task {
      try? await Task.sleep(for: .seconds(seconds))
      continuation.yield(nil)
    }
    var iterator = stream.makeAsyncIterator()
    let result = await iterator.next() ?? nil
    timer.cancel()
    if result == nil { worker.cancel() }
    return result
  }

  @Test func twoStartsRacingYieldOneTakeAndTheOtherIsRejected() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let latch = Latch()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox,
      clock: BlockingClock(base: harness.clock, latch: latch))

    let first = Task { try? await session.start(request) }
    await latch.waitForArrival()  // the first start is suspended on the clock
    let second = Task { try? await session.start(request) }
    try await Task.sleep(for: .milliseconds(50))  // the second start has reached the session
    await latch.open()
    let winners = [await first.value, await second.value].compactMap { $0 }

    #expect(winners.count == 1, "exactly one start wins")
    #expect(await session.current.phase == .recording, "the winner's take is the state, not the loser's cleanup")
    #expect(await session.current.memoID == winners.first)
    #expect(await harness.outbox.items().map(\.memoID) == winners)
    await fake.record(seconds: 2)
    let result = try await session.stop()
    #expect(result?.memoID == winners.first)
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aCancelArrivingWhileTheTakeIsStartingLeavesNothingRecording() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let latch = Latch()
    let session = CaptureSession(
      session: BlockingSession(base: fake.session, latch: latch), routes: fake.routes, recorder: fake.recorder,
      outbox: harness.outbox, clock: harness.clock)

    let starting = Task { try await session.start(request) }
    await latch.waitForArrival()  // start is suspended inside configure()
    let cancelling = Task { await session.cancel() }
    try await Task.sleep(for: .milliseconds(50))  // the cancel has reached the session
    await latch.open()
    _ = try? await starting.value
    await cancelling.value

    #expect(await session.current == .idle)
    #expect(await harness.outbox.items().isEmpty)
    // The microphone is off: the recorder takes a new take (it refuses while one is still running).
    let again = try await session.start(request)
    #expect(await session.current.memoID == again)
    await session.cancel()
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aCancelDuringStoppingDoesNotStrandTheStop() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = DeferredStopRecorder(base: fake.recorder)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox, clock: harness.clock)

    try await session.start(request)
    await fake.recorder.feed(frames: 3 * SegmentRotationPolicy().sampleRate)
    let stopping = Task { try await session.stop() }
    for _ in 0..<200 where await session.current.phase != .stopping { try await Task.sleep(for: .milliseconds(5)) }
    let cancelling = Task { await session.cancel() }
    try await Task.sleep(for: .milliseconds(50))  // the cancel has reached the session
    try await recorder.finishStop()  // the recorder's drain ends: `.stopped` is published

    let stopped = await within(5) { try? await stopping.value }
    #expect(stopped != nil, "the stop returns instead of hanging on a lost continuation")
    #expect((stopped ?? nil)?.segmentCount == 1)
    _ = await within(5) { await cancelling.value }
    #expect(await session.current == .idle)
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
