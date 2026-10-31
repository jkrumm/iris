import Foundation
import Testing

@testable import IrisCapture

/// Parks chosen `now()` calls (counted from `block(calls:)`) until the test opens them one by one, to hold the session in the
/// middle of a step that the event pump runs without the gate.
private actor ClockGate {
  private var calls = 0
  private var blocked: Set<Int> = []
  private var opened: Set<Int> = []
  private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
  private var arrivalWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  func block(calls numbers: Set<Int>) {
    calls = 0
    blocked = numbers
    opened = []
  }

  func pass() async {
    calls += 1
    let number = calls
    guard blocked.contains(number), !opened.contains(number) else { return }
    for waiter in arrivalWaiters.removeValue(forKey: number) ?? [] { waiter.resume() }
    await withCheckedContinuation { parked[number] = $0 }
  }

  func waitForArrival(of number: Int) async {
    guard parked[number] == nil else { return }
    await withCheckedContinuation { arrivalWaiters[number, default: []].append($0) }
  }

  func open(_ number: Int) {
    opened.insert(number)
    parked.removeValue(forKey: number)?.resume()
  }
}

private struct GatedClock: CaptureClock {
  let base: ManualClock
  let gate: ClockGate

  func now() async -> Date {
    await gate.pass()
    return await base.now()
  }

  func sleep(until deadline: Date) async throws { try await base.sleep(until: deadline) }
}

/// A recorder whose `stop()` flushes the open segment and reports `stopped` (the base recorder's stop) and then fails.
private struct FlushThenThrowRecorder: SegmentRecorder {
  struct StopFailed: Error {}

  let base: FakeSegmentRecorder

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }

  func stop() async throws {
    try await base.stop()
    throw StopFailed()
  }

  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
  func fail(reason: String) async { await base.fail(reason: reason) }
}

/// A failed take's recorder stop runs on the event pump, outside the gate: what a stop or a start does in the middle of it.
struct FailedTakePumpTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  @Test func aRecorderStopIsRegisteredBeforeItSuspendsSoNoTakeStartsUnderIt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let gate = ClockGate()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox,
      clock: GatedClock(base: harness.clock, gate: gate))
    try await session.start(request)
    await fake.record(seconds: 12)
    await gate.block(calls: [1])  // the failed take's stop reads its deadline from the clock first
    await fake.recorder.fail(reason: "engine restart failed")
    await gate.waitForArrival(of: 1)

    // The failed take is cancelled while its recorder stop is still before its first await.
    #expect(await session.cancel() != nil)

    await #expect(throws: CaptureError.engineFailure("the recorder is still stopping")) {
      try await session.start(request)
    }
    await gate.open(1)
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aStopThatArrivesBeforeThePumpHasDeliveredTheTailLeavesTheFinishToThePump() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = FlushThenThrowRecorder(base: fake.recorder)
    let gate = ClockGate()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox,
      clock: GatedClock(base: harness.clock, gate: gate))
    let id = try await session.start(request)
    await fake.record(seconds: 12)  // segment 0 closed, 2 s in the open one
    await gate.block(calls: [2])  // the failed take's grace deadline, read after its recorder stop gave up
    await recorder.fail(reason: "engine restart failed")
    await gate.waitForArrival(of: 2)  // the pump is still inside the failure; the tail and `stopped` sit behind it

    let result = try #require(try await session.stop())
    #expect(result.memoID == id && result.failure == "engine restart failed")
    #expect(await harness.uploader.completed.isEmpty, "the pump finishes the memo, after the tail")

    await gate.open(2)
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)], "the tail is in the take")
    #expect(await harness.uploader.uploaded.map(\.index).sorted() == [0, 1])
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aStopThatFindsNothingClosedYetKeepsTheMemoOpenForTheTailBehindTheFailure() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = FlushThenThrowRecorder(base: fake.recorder)
    let gate = ClockGate()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox,
      clock: GatedClock(base: harness.clock, gate: gate))
    let id = try await session.start(request)
    await fake.record(seconds: 4)  // nothing closed: the only audio is in the open segment, which the stop flushes
    await gate.block(calls: [2])
    await recorder.fail(reason: "engine restart failed")
    await gate.waitForArrival(of: 2)

    await #expect(throws: CaptureError.recordingFailed("engine restart failed")) { try await session.stop() }
    #expect(await harness.outbox.queue().count == 1, "the memo is not discarded under the tail")

    await gate.open(2)
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(
      await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)], "the only audio the take has is sent")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aStopSuspendedWhileThePumpFinishesTheMemoStillReportsTheWholeTakeAndItsFailure() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = FlushThenThrowRecorder(base: fake.recorder)
    let gate = ClockGate()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox,
      clock: GatedClock(base: harness.clock, gate: gate))
    let id = try await session.start(request)
    await fake.record(seconds: 12)
    await gate.block(calls: [2, 3])  // the pump's grace deadline, then the user's stop reading its own
    await recorder.fail(reason: "engine restart failed")
    await gate.waitForArrival(of: 2)
    let stopping = Task { try await session.stop() }
    await gate.waitForArrival(of: 3)  // `stop()` is suspended, phase `.stopping`

    await gate.open(2)  // the pump delivers the tail and `stopped`, and finishes the memo with both segments
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)])
    await gate.open(3)

    let result = try #require(try await stopping.value)
    #expect(result.segmentCount == 2, "the count the pump finished the memo with")
    #expect(result.failure == "engine restart failed", "the failure is not forgotten under the stop")
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
