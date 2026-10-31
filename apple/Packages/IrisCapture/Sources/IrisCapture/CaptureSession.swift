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
  private let deviceEvents: any CaptureEvents
  /// What `take.phase` last reported, so a snapshot that changes nothing about the phase is not an event.
  private var reportedPhase: (phase: TakePhase, memoID: MemoID?)?
  /// When the take stopped recording and why, until it records again: the audio lost in between is `capture.gap`.
  private var gapStart: (at: Date, reason: String)?
  /// How long `stop()` and `cancel()` wait for the recorder's last event before they give up on it.
  private let stopTimeout: TimeInterval
  /// How long to wait between attempts to reactivate the audio session after an interruption or a media-services reset.
  private let reactivationDelay: TimeInterval
  private static let reactivationAttempts = 4

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
  /// Takes whose recorder did not report its last event in time. They are not finished yet: the tail segment the recorder was
  /// flushing can still close and is queued like any other; the `stopped` event (or the grace timer, `lateFinish`) finishes
  /// the memo. Set synchronously by the timeout itself, so there is no moment where a take is neither waiting nor finished.
  private var awaitingStop: Set<MemoID> = []
  /// The grace timer of each take in `awaitingStop` that `stop()` has returned for: when it fires the memo is finished with
  /// the segments that closed, and the take is abandoned.
  private var lateFinish: [MemoID: Task<Void, Never>] = [:]
  /// Takes whose memo was finished (or dropped) without the recorder's last event. Anything the recorder still reports for
  /// them is ignored (a segment closing now would join a memo that is already finished; its file stays for the next
  /// launch's sweep), and the entry goes with the `stopped` event that ends them.
  private var abandoned: Set<MemoID> = []
  /// Recorder stops in flight that `stopRecorder()` is waiting on, settled by the stop itself or by its timer.
  private var stopRaces: [UUID: CheckedContinuation<Bool, any Error>] = [:]
  /// Every recorder stop that has not returned, whoever started it and whether or not it was given up on: the recorder may still
  /// be live (its microphone open), so no new take starts on it and the audio session is not deactivated under it until they do.
  private var unreturnedStops: Set<UUID> = []
  /// A take ended while a recorder stop was still running, so the audio session was left active; the last stop's return
  /// deactivates it (through the gate, so a take that starts meanwhile is not cut off).
  private var deactivationPending = false
  private var finishWaiter: (id: MemoID, continuation: CheckedContinuation<Int?, Never>)?
  /// The gate: true while a start, stop or cancel is running; the others wait in `queue`, first come first served.
  private var isBusy = false
  private var queue: [CheckedContinuation<Void, Never>] = []

  public init(
    session: any AudioSessionController, routes: any RouteManager, recorder: any SegmentRecorder, outbox: Outbox,
    clock: any CaptureClock, stopTimeout: TimeInterval = 10, reactivationDelay: TimeInterval = 0.5,
    events deviceEvents: any CaptureEvents = NoCaptureEvents()
  ) {
    self.deviceEvents = deviceEvents
    self.session = session
    self.routes = routes
    self.recorder = recorder
    self.outbox = outbox
    self.clock = clock
    self.stopTimeout = stopTimeout
    self.reactivationDelay = reactivationDelay
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
    // A recorder that never answered its stop may still hold the microphone: a new take waits until it has.
    guard unreturnedStops.isEmpty else { throw CaptureError.engineFailure("the recorder is still stopping") }
    let memoID = MemoID()
    deactivationPending = false  // this take activates the session itself
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
      forget(memoID)
      await deactivateSession()
      setState(.idle)
      throw error
    }
    state.phase = .recording
    publish()
    // A failure that came in while the recorder was starting was parked; the take is up now, so it can fail.
    if let reason = failures[memoID] { await failTake(memoID, reason) }
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
    var recorderAnswered = true
    if !recorderStopped {
      do {
        recorderAnswered = try await stopRecorder()
      } catch {
        await outbox.discard(memoID)
        forget(memoID)
        await deactivateSession()
        setState(.idle)
        throw error
      }
    }
    let reported: Int?
    if recorderAnswered {
      // A failed take whose recorder could not be stopped is already waiting out its grace: the user's stop ends the wait.
      reported = awaitingStop.contains(memoID) ? nil : await finishedCount(memoID)
    } else if let done = finished.removeValue(forKey: memoID) {
      // `stop()` hung but the recorder did emit `stopped`: the pump has finished the memo with the whole take already.
      reported = done
    } else {
      // A `stop()` that never returned counts as a recorder that never said it stopped.
      reported = markSilent(memoID)
    }
    var count = reported ?? closedCounts[memoID, default: 0]
    var holdsOpen = false
    if reported != nil {
      // A failed take's last event was held back for this stop, which sends what it has.
      if recorderStopped, count > 0 { await outbox.finishMemo(memoID, segmentCount: count) }
    } else {
      // Read before the check below: nothing suspends between the check and arming the grace timer, so a `stopped` cannot
      // slip in between and leave the take half cleaned up.
      let graceDeadline = await clock.now().addingTimeInterval(stopTimeout)
      if awaitingStop.contains(memoID) {
        // The recorder never said it stopped: the segments that closed are what the take has so far, and the failure says why.
        if failures[memoID] == nil { failures[memoID] = Self.recorderSilent }
        if count == 0, !recorderStopped {
          awaitingStop.remove(memoID)
          lateFinish.removeValue(forKey: memoID)?.cancel()
          abandoned.insert(memoID)
        } else {
          // The tail segment it was flushing may still close (a failed take's recorder may have queued it, with `stopped`,
          // behind the failure the pump is still handling, and with nothing closed yet it is the whole take), so the memo is
          // finished by the pump when `stopped` arrives, or by the grace period, not now.
          holdsOpen = true
          startGrace(for: memoID, until: graceDeadline)
        }
      } else {
        // `stopped` came in between the timeout and here, and the event pump finished the memo with the whole take.
        count = finished[memoID] ?? count
      }
    }
    let failure = failures[memoID]
    if !holdsOpen { forget(memoID) }
    await deactivateSession()
    setState(.idle)
    guard count > 0 else {
      // A memo held open stays for the tail the pump may still deliver; the pump or the grace period drops it if none comes.
      if !holdsOpen { await outbox.discard(memoID) }
      if let failure { throw CaptureError.recordingFailed(failure) }
      return nil
    }
    return TakeResult(memoID: memoID, segmentCount: count, startedAt: startedAt, failure: failure)
  }

  /// Drops the take: nothing is sent, the memo is discarded from the outbox and the files are deleted. Returns the memo it
  /// discarded, or `nil` when there was nothing to drop: a `stop()` that was already running holds the gate first, so the take
  /// is over (and sent) by the time this gets it. Callers act on the memo they get back (hide it, delete it), never on the
  /// one they saw before the call.
  @discardableResult
  public func cancel() async -> MemoID? {
    await enter()
    defer { leave() }
    guard let memoID = state.memoID, state.phase != .idle else { return nil }
    state.phase = .stopping
    publish()
    // Discarded first so a segment that closes while the recorder stops is deleted, not queued.
    cancelled.insert(memoID)
    await outbox.discard(memoID)
    deviceEvents.event("take.discarded", memoID: memoID, ["segments": .int(closedCounts[memoID, default: 0])])
    // A failed take's recorder is already stopped (it has nothing to flush, and no last event to wait for).
    if state.failure == nil {
      do {
        let answered = try await stopRecorder()
        let reported = answered ? await finishedCount(memoID) : nil
        if reported == nil {
          awaitingStop.remove(memoID)
          abandoned.insert(memoID)
        }
      } catch {
        Log.capture.error("recorder stop after cancel failed: \(String(describing: error), privacy: .public)")
      }
    }
    forget(memoID)
    lateFinish.removeValue(forKey: memoID)?.cancel()
    awaitingStop.remove(memoID)
    await deactivateSession()
    setState(.idle)
    return memoID
  }

  public func pause() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording else { return }
    await recorder.pause()
    // The recorder may have failed while the pause was in flight (the event pump does not wait for the gate).
    guard state.phase == .recording else { return }
    state.phase = .paused
    publish()
    await beginGap("pause")
  }

  public func resume() async {
    await enter()
    defer { leave() }
    guard state.phase == .paused else { return }
    await recorder.resume()
    guard state.phase == .paused else { return }
    state.phase = .recording
    publish()
    await endGap()
  }

  /// The user picks another microphone: the segment rolls over so each file has one input.
  public func switchInput(to uid: String) async throws {
    await enter()
    defer { leave() }
    guard state.phase == .recording || state.phase == .paused else { throw CaptureError.notRecording }
    try await routes.setPreferredInput(uid: uid)
    guard state.phase == .recording || state.phase == .paused else { return }
    await recorder.rotate(for: .micSwitch)
    state.inputName = await routes.currentRoute().currentInput?.name
    publish()
  }

  public func shutdown() {
    for pump in pumps { pump.cancel() }
    pumps = []
    for timer in lateFinish.values { timer.cancel() }
    lateFinish = [:]
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
          case .segmentClosed(let segment, let reason):
            // What became of the file: a segment that closed but was never uploaded is an alarm unless the take was dropped.
            let disposition =
              cancelled.contains(segment.memoID) ? "discarded" : abandoned.contains(segment.memoID) ? "late" : "queued"
            deviceEvents.event(
              "capture.segment.closed", memoID: segment.memoID,
              [
                "index": .int(segment.index), "bytes": .int(segment.byteCount), "seconds": .double(segment.duration),
                "reason": .string(reason.eventName), "closed_ok": .bool(segment.byteCount > 0),
                "disposition": .string(disposition),
              ])
            if disposition == "discarded" {
              try? FileManager.default.removeItem(at: segment.fileURL)
            } else if disposition == "late" {
              // Late: the memo was finished without it. Not queued; the file stays for the next launch's sweep to set aside.
              Log.capture.error("segment \(segment.index) closed after its take was finished, left on disk")
            } else {
              closedCounts[segment.memoID, default: 0] += 1
              await outbox.enqueue(segment)
            }
          case .stopped(let memoID, let count):
            let kept = keptCount(memoID, reported: count)
            // A stop that gave up on this event and then finished the memo (cancel, or the grace period ran out) is over.
            if abandoned.remove(memoID) != nil { break }
            // A stop that gave up on this event left the memo open for it: the take is whole, tail included.
            let graceTimer = lateFinish.removeValue(forKey: memoID)
            graceTimer?.cancel()
            awaitingStop.remove(memoID)
            // A failed take sends what it captured now, not when the user next looks at the phone: the screen may be locked,
            // and the app may be killed before a stop that never comes. `stop()` after that finds the memo already finished.
            if !cancelled.contains(memoID) { await outbox.finishMemo(memoID, segmentCount: kept) }
            didFinish(memoID, count: kept)
            // `stop()` has returned; nobody else will clear the take. A take still held for the user, or for a `stop()` that is
            // reading it right now, keeps its state: that stop consumes it.
            if graceTimer != nil, !isHeldForStop(memoID) {
              // The stop left the memo open for a tail and none came: it has nothing to send.
              if kept == 0, !cancelled.contains(memoID) { await outbox.discard(memoID) }
              forget(memoID)
            }
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
          case .mediaServicesReset: await self.mediaServicesReset()
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
    guard let memoID = state.memoID, state.phase != .idle, !cancelled.contains(memoID) else { return }
    if failures[memoID] == nil { failures[memoID] = reason }
    // Starting: `start` moves the take to failed once it is up. Stopping: `stop` reports the failure with its result.
    guard state.phase == .recording || state.phase == .paused else { return }
    await failTake(memoID, failures[memoID] ?? reason)
  }

  /// The take is recording or paused and its recorder has failed: stop the recorder and hold the take for the user.
  private func failTake(_ memoID: MemoID, _ reason: String) async {
    state.phase = .failed
    state.failure = reason
    publish()
    let answered: Bool
    do {
      // Flushes what it has and emits `.stopped`; bounded, because this runs on the event pump.
      answered = try await stopRecorder()
    } catch {
      Log.capture.error("recorder stop after failure failed: \(String(describing: error), privacy: .public)")
      answered = false
    }
    // Answered: `.stopped` follows and the pump finishes the memo.
    guard !answered, state.memoID == memoID, !cancelled.contains(memoID) else { return }
    // No answer: the recorder may still have put its tail segment and `stopped` on the stream, and they sit behind the failure
    // this very pump is handling. So the memo is not finished now: it waits as a stop that went silent does, and the pump
    // delivers whatever is queued; `stopped` finishes the memo with the whole take, and the grace period (or the user's own
    // stop) with the segments that closed. Either way it goes up without the user having to look at the phone.
    awaitingStop.insert(memoID)
    let deadline = await clock.now().addingTimeInterval(stopTimeout)
    // A `stop()` in that suspension has armed the grace itself, and `stopped` may even have ended the wait.
    guard awaitingStop.contains(memoID) else { return }
    startGrace(for: memoID, until: deadline)
  }

  /// Whether the take's recorder went silent and the memo waits for its `stopped` or the grace period (tests wait on it).
  func isWaitingOutSilentRecorder(_ memoID: MemoID) -> Bool { awaitingStop.contains(memoID) }

  /// The take is the current one and either failed and waiting for the user to stop it, or being stopped right now: its count
  /// and failure are that stop's to read, so the pump keeps them instead of forgetting the take.
  private func isHeldForStop(_ memoID: MemoID) -> Bool {
    state.memoID == memoID && (state.phase == .failed || state.phase == .stopping)
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

  /// The pump has handed the stopped take to the outbox; returns its segment count, or `nil` when the recorder's last
  /// event did not come within `stopTimeout` (the gate must not be held for ever by a recorder that went silent).
  private func finishedCount(_ memoID: MemoID) async -> Int? {
    // The deadline is read before the check, so nothing suspends between the check and the waiter being registered.
    let deadline = await clock.now().addingTimeInterval(stopTimeout)
    if let count = finished.removeValue(forKey: memoID) { return count }
    // Owned by this call; ends with the wait.
    let timer = Task { [clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      self.finishTimedOut(memoID)
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { finishWaiter = (memoID, $0) }
  }

  private func finishTimedOut(_ memoID: MemoID) {
    guard let waiter = finishWaiter, waiter.id == memoID else { return }
    Log.capture.error("recorder did not report within \(self.stopTimeout, privacy: .public) s")
    // Registered before the waiter is resumed: a `stopped` that the pump handles before `stop()` runs again finds the take
    // waiting, not unknown.
    awaitingStop.insert(memoID)
    finishWaiter = nil
    waiter.continuation.resume(returning: nil)
  }

  /// A recorder whose `stop()` never returned is treated like one that never reported.
  private func markSilent(_ memoID: MemoID) -> Int? {
    Log.capture.error("recorder stop did not return within \(self.stopTimeout, privacy: .public) s")
    awaitingStop.insert(memoID)
    return nil
  }

  /// Stops the recorder, giving up after `stopTimeout` (`false`): a recorder whose `stop()` never returns must not hold the
  /// gate or the event pump for ever, and the next take must be able to start. The stop stays on `unreturnedStops` until the
  /// recorder answers; its late answer finds no waiter and is ignored.
  private func stopRecorder() async throws -> Bool {
    let id = UUID()
    // Registered before the first suspension: this runs on the event pump too (`failTake`), outside the gate, and a take that
    // is cancelled and replaced while the clock is read would start under a stop nobody knows about.
    unreturnedStops.insert(id)
    let deadline = await clock.now().addingTimeInterval(stopTimeout)
    // Owned by this call. The stop ends when the recorder answers (a hung one keeps it, harmlessly); the timer ends with the
    // race.
    Task { [recorder] in
      let result: Result<Bool, any Error>
      do {
        try await recorder.stop()
        result = .success(true)
      } catch {
        result = .failure(error)
      }
      self.stopReturned(id, result)
    }
    let timer = Task { [clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      self.stopGivenUp(id)
    }
    defer { timer.cancel() }
    return try await withCheckedThrowingContinuation { stopRaces[id] = $0 }
  }

  /// Deactivates the audio session, unless a recorder stop has not returned: that recorder may still hold the microphone and its
  /// engine, and pulling the session from under it is worse than leaving it active a while. The deactivation is then done by
  /// `stopsDrained` when the last stop returns.
  private func deactivateSession() async {
    guard unreturnedStops.isEmpty else {
      deactivationPending = true
      return
    }
    deactivationPending = false
    try? await session.deactivate()
  }

  /// A recorder stop has returned. When the take that left the session active is over and no stop remains, the session goes.
  private func stopReturned(_ id: UUID, _ result: Result<Bool, any Error>) {
    unreturnedStops.remove(id)
    stopRaces.removeValue(forKey: id)?.resume(with: result)
    guard deactivationPending, unreturnedStops.isEmpty else { return }
    // Fire and forget, one short deactivation behind the gate; ends on its own.
    Task { await self.stopsDrained() }
  }

  private func stopGivenUp(_ id: UUID) {
    stopRaces.removeValue(forKey: id)?.resume(returning: false)
  }

  /// Behind the gate, like every other change of the session: a take that is starting holds it until it has activated, and finds
  /// the take running when it is this one's turn, so a late deactivation never lands on top of an activation.
  private func stopsDrained() async {
    await enter()
    defer { leave() }
    guard deactivationPending, unreturnedStops.isEmpty, state.phase == .idle else { return }
    deactivationPending = false
    do {
      try await session.deactivate()
    } catch {
      Log.capture.error("deferred audio session deactivation failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Arms the timer that finishes a take whose `stopped` never comes: the segments that closed by then are the take.
  private func startGrace(for memoID: MemoID, until deadline: Date) {
    guard lateFinish[memoID] == nil else { return }
    // Owned by `lateFinish`; ends with the `stopped` event or its own firing, and is cancelled by `shutdown()`.
    lateFinish[memoID] = Task { [clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      await self.graceExpired(memoID)
    }
  }

  private func graceExpired(_ memoID: MemoID) async {
    guard lateFinish.removeValue(forKey: memoID) != nil, awaitingStop.remove(memoID) != nil else { return }
    let count = closedCounts[memoID, default: 0]
    Log.capture.error(
      "recorder never reported the end of \(memoID.uuidString, privacy: .public), finished with \(count) segments")
    // From here a segment that closes is late: its file stays for the next launch's sweep.
    abandoned.insert(memoID)
    if isHeldForStop(memoID) {
      didFinish(memoID, count: count)  // the user's stop finds the memo finished
    } else {
      forget(memoID)
      // The stop left the memo open for a tail and none came.
      if count == 0, !cancelled.contains(memoID) { await outbox.discard(memoID) }
    }
    if count > 0, !cancelled.contains(memoID) { await outbox.finishMemo(memoID, segmentCount: count) }
  }

  private static let recorderSilent = "the recorder did not stop"

  private func interrupted() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording else { return }
    await recorder.pause()
    guard state.phase == .recording else { return }
    state.phase = .paused
    publish()
    await beginGap("interruption")
  }

  private func interruptionEnded(shouldResume: Bool) async {
    await enter()
    defer { leave() }
    guard state.phase == .paused, shouldResume else {
      deviceEvents.event(
        "audio.interruption", memoID: state.memoID,
        ["type": "resume_skipped", "should_resume": .bool(shouldResume), "phase": .string(state.phase.eventName)])
      return
    }
    await resumeRecorder()
  }

  /// The audio daemon restarted under a take: the category and activation are gone and the engine is dead. A recording take
  /// closes its open segment, gets its session back and carries on in a new one. A paused take (the user's pause, or an
  /// interruption that did not recommend resuming) gets its category back and stays paused: a reset is no reason to
  /// start recording what the user, or the system, stopped. A take that cannot be brought back fails and keeps what it has.
  private func mediaServicesReset() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording || state.phase == .paused else { return }
    let wasRecording = state.phase == .recording
    if wasRecording {
      await recorder.pause()
      guard state.phase == .recording else { return }
      state.phase = .paused
      publish()
      await beginGap("media_services_reset")
    }
    do {
      try await retrying { try await session.configure() }
    } catch {
      await sessionLost(error)
      return
    }
    guard wasRecording else { return }
    await resumeRecorder()
  }

  /// Reactivates the session (a session an interruption deactivated makes `engine.start()` fail) and restarts the recorder.
  /// Behind the gate. A session that stays inactive fails the take: its segments are closed, queued and finished.
  private func resumeRecorder() async {
    do {
      try await retrying { try await session.activate() }
    } catch {
      var attributes = CaptureErrorDetail.attributes(of: error)
      attributes["type"] = "resume"
      attributes["resume.result"] = "error"
      deviceEvents.event("audio.interruption", memoID: state.memoID, error: true, attributes)
      await sessionLost(error)
      return
    }
    guard state.phase == .paused else { return }
    await recorder.resume()
    guard state.phase == .paused else { return }
    state.phase = .recording
    publish()
    deviceEvents.event("audio.interruption", memoID: state.memoID, ["type": "resume", "resume.result": "ok"])
    await endGap()
  }

  /// Runs a session call that fails while the audio daemon is not ready, a few times with a pause between, for as long as the
  /// take is still waiting for it.
  private func retrying(_ operation: () async throws -> Void) async throws {
    var attempt = 1
    while true {
      do {
        try await operation()
        return
      } catch {
        guard attempt < Self.reactivationAttempts, state.phase == .paused else { throw error }
        Log.capture.error("session call failed, try \(attempt): \(String(describing: error), privacy: .public)")
        attempt += 1
        let deadline = await clock.now().addingTimeInterval(reactivationDelay)
        try await clock.sleep(until: deadline)
      }
    }
  }

  private func sessionLost(_ error: any Error) async {
    guard let memoID = state.memoID, state.phase == .paused else { return }
    let reason = "audio session could not be restored"
    Log.capture.error("\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
    if failures[memoID] == nil { failures[memoID] = reason }
    await failTake(memoID, reason)
  }

  /// The route changed under a running take. A matching rule switches the input like the user's own switch does, behind the
  /// gate and with the segment rolled over, so one file never holds two inputs; with no take (or one that is ending) the
  /// next `start` applies the rule instead.
  private func routeChanged() async {
    await enter()
    defer { leave() }
    guard state.phase == .recording || state.phase == .paused else { return }
    guard await applyRouteRule() else { return }
    guard state.phase == .recording || state.phase == .paused else { return }
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
    reportPhase()
    for observer in observers.values { observer.yield(state) }
  }

  /// `take.phase` on every change of phase. The app adds which control asked (`source`). `stopped` is the idle after a take.
  private func reportPhase() {
    let memoID = state.memoID ?? reportedPhase?.memoID
    if let reported = reportedPhase, reported.phase == state.phase, reported.memoID == memoID { return }
    if state.phase == .idle, reportedPhase == nil { return }
    reportedPhase = state.phase == .idle ? nil : (state.phase, memoID)
    var attributes: [String: CaptureEventValue] = [
      "phase": .string(state.phase == .idle ? "stopped" : state.phase.eventName)
    ]
    if let mode = state.request?.mode { attributes["mode"] = .string(mode) }
    if let input = state.inputName { attributes["input.name"] = .string(PortLabel.name(input)) }
    if let failure = state.failure { attributes["failure"] = .string(failure) }
    deviceEvents.event("take.phase", memoID: memoID, error: state.phase == .failed, attributes)
  }

  /// The take stopped recording (`reason`): the clock starts on the gap that ends when it records again.
  private func beginGap(_ reason: String) async {
    gapStart = (await clock.now(), reason)
  }

  /// The take records again: `capture.gap` says for how long it did not, and why.
  private func endGap() async {
    guard let start = gapStart else { return }
    gapStart = nil
    let milliseconds = max(0, Int((await clock.now()).timeIntervalSince(start.at) * 1000))
    deviceEvents.event(
      "capture.gap", memoID: state.memoID,
      [
        "ms": .int(milliseconds), "reason": .string(start.reason),
        "frames_lost": .int(milliseconds * SegmentRotationPolicy().sampleRate / 1000),
      ])
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }
}

extension TakePhase {
  /// The name `take.phase` carries.
  fileprivate var eventName: String {
    switch self {
    case .idle: "idle"
    case .starting: "starting"
    case .recording: "recording"
    case .paused: "paused"
    case .stopping: "stopping"
    case .failed: "failed"
    }
  }
}

extension RotationReason {
  /// The name `capture.segment.closed` carries: `rotate` (the 10 s length), `route` (a mic or configuration change), `pause`, `stop`.
  fileprivate var eventName: String {
    switch self {
    case .duration: "rotate"
    case .micSwitch, .configurationChange: "route"
    case .interruption: "pause"
    case .stop: "stop"
    }
  }
}
