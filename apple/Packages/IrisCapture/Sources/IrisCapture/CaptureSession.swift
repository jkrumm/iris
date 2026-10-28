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
  case recording
  /// An interruption (a call) or the user paused it; the take continues in a new segment on resume.
  case paused
  /// `stop()` is flushing the last segment.
  case stopping
}

/// One snapshot of the take for the UI and the Live Activity.
public struct TakeState: Sendable, Equatable {
  public var phase: TakePhase
  public var memoID: MemoID?
  public var startedAt: Date?
  /// The microphone in use, for the Live Activity (device-side only).
  public var inputName: String?
  public var request: TakeRequest?

  public static let idle = TakeState(phase: .idle, memoID: nil, startedAt: nil, inputName: nil, request: nil)
}

/// How a stopped take ended.
public struct TakeResult: Sendable, Equatable {
  public let memoID: MemoID
  public let segmentCount: Int
  public let startedAt: Date
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
  private var finishWaiter: (id: MemoID, continuation: CheckedContinuation<Int, Never>)?

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
    guard state.phase == .idle else { throw CaptureError.alreadyRecording }
    // Claimed before the first suspension so a second start cannot slip in.
    let memoID = MemoID()
    let startedAt = await clock.now()
    state = TakeState(phase: .recording, memoID: memoID, startedAt: startedAt, inputName: nil, request: request)
    do {
      try await session.configure()
      try await session.activate()
      await applyRouteRule()
      startPumps()
      let item = OutboxItem(
        memoID: memoID, kind: .voice, mode: request.mode, threadID: request.threadID, startedAt: startedAt,
        queuedAt: startedAt, title: request.title)
      await outbox.enqueueItem(item)
      try await recorder.start(memoID: memoID)
    } catch {
      await outbox.discard(memoID)
      try? await session.deactivate()
      setState(.idle)
      throw error
    }
    let input = await routes.currentRoute().currentInput?.name
    state.inputName = input
    publish()
    return memoID
  }

  /// Ends the take: the last segment is flushed and the memo is finished in the outbox. A take that never closed a
  /// segment (nothing was said) is dropped and `nil` comes back.
  @discardableResult
  public func stop() async throws -> TakeResult? {
    guard let memoID = state.memoID, state.phase == .recording || state.phase == .paused,
      let startedAt = state.startedAt
    else { throw CaptureError.notRecording }
    state.phase = .stopping
    publish()
    do {
      try await recorder.stop()
    } catch {
      await outbox.discard(memoID)
      try? await session.deactivate()
      setState(.idle)
      throw error
    }
    let count = await finishedCount(memoID)
    try? await session.deactivate()
    setState(.idle)
    guard count > 0 else {
      await outbox.discard(memoID)
      return nil
    }
    return TakeResult(memoID: memoID, segmentCount: count, startedAt: startedAt)
  }

  /// Drops the take: nothing is sent, the memo is discarded from the outbox and the files are deleted.
  public func cancel() async {
    guard let memoID = state.memoID, state.phase != .idle else { return }
    state.phase = .stopping
    publish()
    // Discarded first so a segment that closes while the recorder stops is deleted, not queued.
    cancelled.insert(memoID)
    await outbox.discard(memoID)
    do {
      try await recorder.stop()
      _ = await finishedCount(memoID)
    } catch {
      Log.capture.error("recorder stop after cancel failed: \(String(describing: error), privacy: .public)")
    }
    try? await session.deactivate()
    setState(.idle)
  }

  public func pause() async {
    guard state.phase == .recording else { return }
    await recorder.pause()
    state.phase = .paused
    publish()
  }

  public func resume() async {
    guard state.phase == .paused else { return }
    await recorder.resume()
    state.phase = .recording
    publish()
  }

  /// The user picks another microphone: the segment rolls over so each file has one input.
  public func switchInput(to uid: String) async throws {
    guard state.phase == .recording || state.phase == .paused else { throw CaptureError.notRecording }
    try await routes.setPreferredInput(uid: uid)
    await recorder.rotate(for: .micSwitch)
    state.inputName = await routes.currentRoute().currentInput?.name
    publish()
  }

  public func shutdown() {
    for pump in pumps { pump.cancel() }
    pumps = []
    for observer in observers.values { observer.finish() }
    observers = [:]
  }

  // MARK: Internals

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
              await outbox.enqueue(segment)
            }
          case .stopped(let memoID, let count):
            if !cancelled.contains(memoID) { await outbox.finishMemo(memoID, segmentCount: count) }
            didFinish(memoID, count: count)
          case .failed(let reason): Log.capture.error("recorder failed: \(reason, privacy: .public)")
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
        for await _ in routeChanges { await self.applyRouteRule() }
      },
    ]
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
    guard state.phase == .recording else { return }
    await recorder.pause()
    state.phase = .paused
    publish()
  }

  private func interruptionEnded(shouldResume: Bool) async {
    guard state.phase == .paused, shouldResume else { return }
    await recorder.resume()
    state.phase = .recording
    publish()
  }

  /// A device-local rule for this route ("AirPods in the car -> built-in mic") picks the input.
  private func applyRouteRule() async {
    let route = await routes.currentRoute()
    guard let uid = await routes.rules()[route.fingerprint], uid != route.currentInput?.uid,
      route.availableInputs.contains(where: { $0.uid == uid })
    else { return }
    do {
      try await routes.setPreferredInput(uid: uid)
    } catch {
      Log.capture.error("route rule not applied: \(String(describing: error), privacy: .public)")
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
