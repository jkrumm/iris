import Foundation

/// What a take is for: it becomes one memo on the server.
public struct TakeRequest: Sendable, Equatable {
  /// The `MemoMode` raw value.
  public var mode: String
  /// Continues this thread; `nil` for a new memo.
  public var threadID: String?
  /// The queue row while the take is waiting to be sent.
  public var title: String

  public init(mode: String, threadID: String? = nil, title: String) {
    self.mode = mode
    self.threadID = threadID
    self.title = title
  }
}

public enum TakePhase: Sendable, Equatable {
  case idle
  /// `start()` has claimed the take and is bringing the session and the recorder up.
  case starting
  case recording
  /// An interruption (a call) or the user paused it; the take continues in a new segment on resume.
  case paused
  /// `stop()` is flushing the last segment.
  case stopping
  /// The recorder failed (a write error, an engine that would not restart) and has been stopped. `stop()` ends the take
  /// with the segments it has, or throws when it has none; `cancel()` drops it.
  case failed
}

/// One snapshot of the take for the UI and the Live Activity.
public struct TakeState: Sendable, Equatable {
  public var phase: TakePhase
  public var memoID: MemoID?
  public var startedAt: Date?
  /// The microphone in use, for the Live Activity (device-side only).
  public var inputName: String?
  public var request: TakeRequest?
  /// Why the recorder failed; set with the `failed` phase.
  public var failure: String?

  public static let idle = TakeState(phase: .idle, memoID: nil, startedAt: nil, inputName: nil, request: nil)
}

/// How a stopped take ended.
public struct TakeResult: Sendable, Equatable {
  public let memoID: MemoID
  public let segmentCount: Int
  public let startedAt: Date
  /// The recorder failed during the take: the memo holds what was captured before that, not the whole take.
  public var failure: String?
}

/// The coordinator of one take: session, route, recorder and outbox behind one handle.
///
/// `start` registers the memo with the outbox and starts the recorder; every closed segment goes to the outbox while the
/// take is still running. The outbox creates the memo on the server once the take has its first segment (or ends), so a
/// take cancelled early leaves nothing behind. `stop` flushes the last segment and finishes the memo. Interruptions pause the recorder at a segment
/// boundary and resume it when the system says so. Call `shutdown()` when the app is done with the session: it cancels
/// the event pumps this actor owns.
public actor CaptureSession {
  private let session: any AudioSessionController
  private let routes: any RouteManager
  private let recorder: any SegmentRecorder
  private let outbox: Outbox
  private let clock: any CaptureClock

  private var state = TakeState.idle
  private var observers: [UUID: AsyncStream<TakeState>.Continuation] = [:]
  private var pumps: [Task<Void, Never>] = []
  private var finished: [MemoID: Int] = [:]
  /// Takes that were cancelled: the segment still closing at the stop is deleted, not queued.
  private var cancelled: Set<MemoID> = []
  /// Segments that closed per take, so a failed take knows what it has without waiting for the recorder's last event.
  private var closedCounts: [MemoID: Int] = [:]
  /// Why the recorder failed, per take.
  private var failures: [MemoID: String] = [:]
  private var finishWaiter: (id: MemoID, continuation: CheckedContinuation<Int, Never>)?
  /// The gate: true while a start, stop or cancel is running; the others wait in `queue`, first come first served.
  private var isBusy = false
  private var queue: [CheckedContinuation<Void, Never>] = []

  public init(
    session: any AudioSessionController, routes: any RouteManager, recorder: any SegmentRecorder, outbox: Outbox,
    clock: any CaptureClock
  ) {
    self.session = session
    self.routes = routes
    self.recorder = recorder
    self.outbox = outbox
    self.clock = clock
  }

  public var current: TakeState { state }

  /// Input level in 0...1 while a take runs, for the waveform.
  public nonisolated var levels: AsyncStream<Float> { recorder.levels }

  /// Snapshots of the take, starting with the current one; ends at `shutdown()`.
  public func updates() -> AsyncStream<TakeState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(of: TakeState.self, bufferingPolicy: .bufferingNewest(1))
    observers[id] = continuation
    continuation.yield(state)
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeObserver(id) }
    }
    return stream
  }

  // MARK: Take

  /// Starts a take and returns its memo id (minted here: it is also the trace id).
  @discardableResult
  public func start(_ request: TakeRequest) async throws -> MemoID {
    await enter()
    defer { leave() }
    guard state.phase == .idle else { throw CaptureError.alreadyRecording }
    let memoID = MemoID()
    // Claimed with no suspension between the guard and here (the gate is ours): nothing else sees an idle session.
    state = TakeState(phase: .starting, memoID: memoID, startedAt: nil, inputName: nil, request: request)
    publish()
    let startedAt = await clock.now()
    state.startedAt = startedAt
    do {
      try await session.configure()
      try await session.activate()
      _ = await applyRouteRule()
      startPumps()
      let item = OutboxItem(
        memoID: memoID, kind: .voice, mode: request.mode, threadID: request.threadID, startedAt: startedAt,
        queuedAt: startedAt, title: request.title)
      try await outbox.enqueueItem(item)
      try await recorder.start(memoID: memoID)
    } catch {
      await outbox.discard(memoID)
      try? await session.deactivate()
      setState(.idle)
      throw error
    }
    state.phase = .recording
    state.inputName = await routes.currentRoute().currentInput?.name
    publish()
    return memoID
  }

  /// Ends the take: the last segment is flushed and the memo is finished in the outbox. A take that never closed a
  /// segment (nothing was said) is dropped and `nil` comes back. A take whose recorder failed ends with the segments it
  /// has (`TakeResult.failure` says why), or throws `CaptureError.recordingFailed` when it has none: the audio is lost,
  /// which is not the same as nothing having been said.
  @discardableResult
  public func stop() async throws -> TakeResult? {
    await enter()
    defer { leave() }
    guard let memoID = state.memoID, state.phase == .recording || state.phase == .paused || state.phase == .failed,
      let startedAt = state.startedAt
    else { throw CaptureError.notRecording }
    // A failed take's recorder was stopped when the failure came in.
    let recorderStopped = state.phase == .failed
    state.phase = .stopping
    publish()
    if !recorderStopped {
      do {
        try await recorder.stop()
      } catch {
        await outbox.discard(memoID)
        forget(memoID)
        try? await session.deactivate()
        setState(.idle)
        throw error
      }
    }
    let count = await finishedCount(memoID)
    let failure = failures[memoID]
    if recorderStopped, count > 0 { await outbox.finishMemo(memoID, segmentCount: count) }
    forget(memoID)
    try? await session.deactivate()
    setState(.idle)
    guard count > 0 else {
      await outbox.discard(memoID)
      if let failure { throw CaptureError.recordingFailed(failure) }
      return nil
    }
    return TakeResult(memoID: memoID, segmentCount: count, startedAt: startedAt, failure: failure)
  }

  /// Drops the take: nothing is sent, the memo is discarded from the outbox and the files are deleted.
  public func cancel() async {
    await enter()
    defer { leave() }
    guard let memoID = state.memoID, state.phase != .idle else { return }
    state.phase = .stopping
    publish()
    // Discarded first so a segment that closes while the recorder stops is deleted, not queued.
    cancelled.insert(memoID)
    await outbox.discard(memoID)
    // A failed take's recorder is already stopped (it has nothing to flush, and no last event to wait for).
    if state.failure == nil {
      do {
        try await recorder.stop()
        _ = await finishedCount(memoID)
      } catch {
        Log.capture.error("recorder stop after cancel failed: \(String(describing: error), privacy: .public)")
      }
    }
    forget(memoID)
    try? await session.deactivate()
    setState(.idle)
  }

  public func pause() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording else { return }
    await recorder.pause()
    state.phase = .paused
    publish()
  }

  public func resume() async {
    await enter()
    defer { leave() }
    guard state.phase == .paused else { return }
    await recorder.resume()
    state.phase = .recording
    publish()
  }

  /// The user picks another microphone: the segment rolls over so each file has one input.
  public func switchInput(to uid: String) async throws {
    await enter()
    defer { leave() }
    guard state.phase == .recording || state.phase == .paused else { throw CaptureError.notRecording }
    try await routes.setPreferredInput(uid: uid)
    await recorder.rotate(for: .micSwitch)
    state.inputName = await routes.currentRoute().currentInput?.name
    publish()
  }

  public func shutdown() {
    for pump in pumps { pump.cancel() }
    pumps = []
    // A stop still waiting for the recorder's last event would wait for ever once the pumps are gone.
    if let waiter = finishWaiter {
      finishWaiter = nil
      waiter.continuation.resume(returning: 0)
    }
    for observer in observers.values { observer.finish() }
    observers = [:]
  }

  // MARK: Internals

  /// Takes the gate, waiting in line when a start, stop or cancel is running. The check and the claim have no suspension
  /// between them, so the gate is never held by two.
  private func enter() async {
    guard isBusy else {
      isBusy = true
      return
    }
    await withCheckedContinuation { queue.append($0) }
  }

  /// Hands the gate to the next in line, or opens it.
  private func leave() {
    guard !queue.isEmpty else {
      isBusy = false
      return
    }
    queue.removeFirst().resume()
  }

  private func startPumps() {
    guard pumps.isEmpty else { return }
    let events = recorder.events
    let interruptions = session.interruptions
    let routeChanges = routes.routeChanges
    // Owned by `pumps`; cancelled by `shutdown()`.
    pumps = [
      Task { [outbox] in
        for await event in events {
          switch event {
          case .segmentClosed(let segment, _):
            if cancelled.contains(segment.memoID) {
              try? FileManager.default.removeItem(at: segment.fileURL)
            } else {
              closedCounts[segment.memoID, default: 0] += 1
              await outbox.enqueue(segment)
            }
          case .stopped(let memoID, let count):
            // A failed take waits for the user's stop (which sends what it has) or cancel (which drops it).
            let isHeldBack = state.phase == .failed && state.memoID == memoID
            let kept = keptCount(memoID, reported: count)
            if !cancelled.contains(memoID), !isHeldBack { await outbox.finishMemo(memoID, segmentCount: kept) }
            didFinish(memoID, count: kept)
          case .failed(let reason): await recorderFailed(reason)
          case .started: continue
          }
        }
      },
      Task {
        for await event in interruptions {
          switch event {
          case .began: await self.interrupted()
          case .ended(let shouldResume): await self.interruptionEnded(shouldResume: shouldResume)
          }
        }
      },
      Task {
        for await _ in routeChanges { await self.routeChanged() }
      },
    ]
  }

  /// The recorder reported a failure. Called from the event pump, so it never waits for the gate: a `stop()` holding the
  /// gate is waiting for the recorder's last event, which sits behind this one in the same stream.
  private func recorderFailed(_ reason: String) async {
    Log.capture.error("recorder failed: \(reason, privacy: .public)")
    guard let memoID = state.memoID, state.phase != .idle, state.phase != .starting, !cancelled.contains(memoID) else {
      return
    }
    failures[memoID] = reason
    guard state.phase == .recording || state.phase == .paused else { return }  // a stop is already ending the take
    state.phase = .failed
    state.failure = reason
    publish()
    do {
      try await recorder.stop()  // flushes what it has and emits `.stopped`
    } catch {
      // No last event is coming: the segments that closed are what the take has.
      Log.capture.error("recorder stop after failure failed: \(String(describing: error), privacy: .public)")
      didFinish(memoID, count: closedCounts[memoID, default: 0])
    }
  }

  /// The segments a take really has. After a recorder failure its own count can include a segment it never managed to
  /// close (a file that could not be written), which the memo would wait for ever: the closed ones are the truth.
  private func keptCount(_ memoID: MemoID, reported: Int) -> Int {
    guard failures[memoID] != nil else { return reported }
    return min(reported, closedCounts[memoID, default: 0])
  }

  private func forget(_ memoID: MemoID) {
    closedCounts[memoID] = nil
    failures[memoID] = nil
    finished[memoID] = nil
  }

  private func didFinish(_ memoID: MemoID, count: Int) {
    finished[memoID] = count
    if let waiter = finishWaiter, waiter.id == memoID {
      finishWaiter = nil
      waiter.continuation.resume(returning: count)
    }
  }

  /// The pump has handed the stopped take to the outbox; returns its segment count.
  private func finishedCount(_ memoID: MemoID) async -> Int {
    if let count = finished.removeValue(forKey: memoID) { return count }
    return await withCheckedContinuation { finishWaiter = (memoID, $0) }
  }

  private func interrupted() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording else { return }
    await recorder.pause()
    state.phase = .paused
    publish()
  }

  private func interruptionEnded(shouldResume: Bool) async {
    await enter()
    defer { leave() }
    guard state.phase == .paused, shouldResume else { return }
    await recorder.resume()
    state.phase = .recording
    publish()
  }

  /// The route changed under a running take. A matching rule switches the input like the user's own switch does, behind the
  /// gate and with the segment rolled over, so one file never holds two inputs; with no take (or one that is ending) the
  /// next `start` applies the rule instead.
  private func routeChanged() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording || state.phase == .paused else { return }
    guard await applyRouteRule() else { return }
    await recorder.rotate(for: .micSwitch)
    state.inputName = await routes.currentRoute().currentInput?.name
    publish()
  }

  /// A device-local rule for this route ("AirPods in the car -> built-in mic") picks the input. `true` when it changed it.
  private func applyRouteRule() async -> Bool {
    let route = await routes.currentRoute()
    guard let uid = await routes.rules()[route.fingerprint], uid != route.currentInput?.uid,
      route.availableInputs.contains(where: { $0.uid == uid })
    else { return false }
    do {
      try await routes.setPreferredInput(uid: uid)
      return true
    } catch {
      Log.capture.error("route rule not applied: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  private func setState(_ new: TakeState) {
    state = new
    publish()
  }

  private func publish() {
    for observer in observers.values { observer.yield(state) }
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}
