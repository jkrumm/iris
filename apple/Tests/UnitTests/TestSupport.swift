import Foundation
import IrisCapture
import IrisCore
import Synchronization
import Testing

@testable import Iris

/// A credential store that lives in memory, so no unit test touches the Keychain or `UserDefaults`.
final class InMemoryCredentialStore: CredentialStore {
  private let credentials = Mutex<ConnectionCredentials?>(nil)

  init(_ credentials: ConnectionCredentials? = nil) {
    self.credentials.withLock { $0 = credentials }
  }

  func set(_ value: ConnectionCredentials?) { credentials.withLock { $0 = value } }
  func load() -> ConnectionCredentials? { credentials.withLock { $0 } }
  func save(_ value: ConnectionCredentials) throws { set(value) }
  func clear() { set(nil) }
}

/// Waits for a held call to arrive, but never forever: a gate on an endpoint the fake does not gate (or a call that
/// never happens) fails the test after `seconds` instead of hanging the whole run.
func waitUntilHeld(_ gate: FakeAPIClient.Gate, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation)
  async -> Bool
{
  let arrived = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await gate.waitUntilHeld()
      return !Task.isCancelled
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(seconds))
      return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
  }
  if !arrived { Issue.record("no call was held within \(seconds) s", sourceLocation: sourceLocation) }
  return arrived
}

/// The app's capture stack on fakes: the real uploader over a `FakeAPIClient`, a fake recorder and a manual clock, so a
/// test moves retry timers by hand. Segment files live in a temporary directory of their own.
@MainActor
struct OutboxRig {
  let service: OutboxService
  let stack: CaptureStack
  let capture: FakeCapture
  let clock: ManualClock
  let created: CreatedMemoLog

  /// `recorder` wraps the fake recorder (a recorder whose stop hangs, say); by default the take records on the fake itself.
  init(
    client: FakeAPIClient, store: any OutboxStore = InMemoryOutboxStore(), clock: ManualClock = ManualClock(),
    recorder: (FakeSegmentRecorder) -> any SegmentRecorder = { $0 }
  ) {
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)"))
    let created = CreatedMemoLog()
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes, recorder: recorder(capture.recorder), clock: clock,
        store: store,
        uploader: APIOutboxUploader(client: client, created: created), policy: OutboxPolicy(jitter: { 0 })))
    self.capture = capture
    self.clock = clock
    self.created = created
    self.stack = stack
    service = OutboxService(stack: stack, created: created, now: { MemoFactory.now })
  }

  /// A voice reply that feeds `seconds` of silence just before the take ends.
  func voice(seconds: Double = 3) -> OutboxVoiceReplyCapture {
    OutboxVoiceReplyCapture(
      stack: stack, service: service, willEnd: { [capture] in await capture.recordWithoutClock(seconds: seconds) })
  }

  /// Waits (bounded) until the queue is empty: the outbox has sent everything.
  func drain(seconds: Double = 10) async -> Bool {
    guard let outbox = try? await stack.outbox() else { return false }
    for _ in 0..<Int(seconds * 100) {
      await outbox.settled()
      if await outbox.queue().isEmpty { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

extension FakeCapture {
  /// Frames into the recorder without stepping the capture clock.
  func recordWithoutClock(seconds: Double) async {
    await recorder.feed(frames: Int(seconds * 16_000))
  }
}

/// The sleeps of the toast timers, each released by the test; a cancelled sleep throws, as `Task.sleep` does.
final class ToastTimers {
  private var gates: [AsyncStream<Void>.Continuation] = []

  func sleep(_ duration: Duration) async throws {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    gates.append(gate)
    for await _ in stream { return }
    try Task.checkCancellation()
  }

  func fire(_ index: Int) {
    gates[index].yield()
  }

  /// Waits until `count` sleeps have started; bounded, a missing sleep fails the test.
  func waitForSleeps(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    let reached = await until { gates.count >= count }
    if !reached { Issue.record("fewer than \(count) toast timers started", sourceLocation: sourceLocation) }
  }

  /// Lets the main actor run what a fired or cancelled timer queued.
  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  /// Yields until `condition` holds, at most a few thousand times; the answer says whether it did.
  func until(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<5_000 {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }
}
