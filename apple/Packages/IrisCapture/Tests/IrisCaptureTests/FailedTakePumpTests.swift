import Foundation
import Testing

@testable import IrisCapture

/// Parks one chosen `now()` call (counted from `block(call:)`) until the test opens it, to hold the session in the middle of
/// a step that the event pump runs without the gate.
private actor ClockGate {
  private var calls = 0
  private var blockedCall: Int?
  private var isOpen = false
  private var parked: CheckedContinuation<Void, Never>?
  private var arrived = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

  func block(call number: Int) {
    calls = 0
    blockedCall = number
    isOpen = false
    arrived = false
  }

  func pass() async {
    calls += 1
    guard calls == blockedCall, !isOpen else { return }
    arrived = true
    for waiter in arrivalWaiters { waiter.resume() }
    arrivalWaiters = []
    await withCheckedContinuation { parked = $0 }
  }

  func waitForArrival() async {
    guard !arrived else { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func open() {
    isOpen = true
    parked?.resume()
    parked = nil
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
    await gate.block(call: 1)  // the failed take's stop reads its deadline from the clock first
    await fake.recorder.fail(reason: "engine restart failed")
    await gate.waitForArrival()

    // The failed take is cancelled while its recorder stop is still before its first await.
    #expect(await session.cancel() != nil)

    await #expect(throws: CaptureError.engineFailure("the recorder is still stopping")) {
      try await session.start(request)
    }
    await gate.open()
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
