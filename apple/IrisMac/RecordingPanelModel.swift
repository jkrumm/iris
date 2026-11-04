import Foundation
import IrisCapture
import IrisCore
import Observation
import os

/// The state machine behind the floating recording panel: what a take on the Mac looks like from the hotkey and the panel's
/// buttons. It decides nothing about audio; the ``TakeEngine`` does, so every path here runs on fakes.
///
/// ```
/// idle ── toggle ──▶ starting ──▶ recording ── toggle / Stop ──▶ stopping ──▶ idle
///   ▲                 │  │            │ Cancel ───────────────────────────────▶ idle
///   │      Cancel ────┘  └─ deadline / start refused ─▶ failed ◀── engine failed (partial take is kept) / stop lost the audio
///   └── dismiss ◀───────────────────────────────────────┘
/// ```
///
/// Presses and buttons are ignored while a start or a stop is running, except Cancel, which abandons a start (also one that has
/// just succeeded: the take is discarded, never shown as recording). A start that has not answered by its deadline (the engine
/// ``startDeadline``, the permission prompt ``permissionDeadline``) ends as `failed(.couldNotStart)`, so a wedged prompt or engine
/// never locks the hotkey.
/// The panel shows whenever the phase is not `idle`.
@MainActor
@Observable
final class RecordingPanelModel {
  enum Phase: Equatable {
    case idle
    /// The permission prompt or the engine is coming up.
    case starting
    case recording(since: Date)
    case stopping
    case failed(Failure)
  }

  /// Why the panel stays up with a message. Details go to the log, never to the screen.
  enum Failure: Equatable {
    /// No server URL and token saved: a memo could not be sent.
    case notConfigured
    /// The system refused the microphone (System Settings › Privacy & Security › Microphone).
    case microphoneDenied
    case couldNotStart
    /// The take ended without closing a segment: nothing was said, or it was too short.
    case nothingRecorded
    /// The recorder failed mid-take; what closed before that is in the outbox.
    case stoppedEarly
    /// Stopping did not keep the audio.
    case lost
  }

  private(set) var phase = Phase.idle {
    didSet {
      if (oldValue != .idle) != (phase != .idle) { onVisibilityChange?(phase != .idle) }
      if oldValue != phase { onPhaseChange?(phase) }
    }
  }
  /// The input level 0...1 and the last few, newest last, for the waveform.
  private(set) var level: Float = 0
  private(set) var recentLevels: [Float] = []
  private(set) var microphones = Microphones()
  /// Told whenever the panel should appear or go (`true` = show).
  @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?
  /// Told every new phase (the device log's `mac.panel`).
  @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
  /// Told which control a command came from, before it runs: `hotkey` or `panel` (the device log's `source`).
  @ObservationIgnored var onCommand: ((String) -> Void)?

  static let waveformBars = 48

  @ObservationIgnored private let engine: any TakeEngine
  @ObservationIgnored private let permission: any MicrophonePermission
  @ObservationIgnored private let isConfigured: () -> Bool
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var isBusy = false
  @ObservationIgnored private let startDeadline: Duration
  @ObservationIgnored private let permissionDeadline: Duration
  /// Cancel was pressed during `.starting`; `begin()` checks it before the take is shown as recording.
  @ObservationIgnored private var cancelRequested = false
  /// Counts the newer sources of the microphone list (a switch, a device change), so a slow first load never overwrites them.
  @ObservationIgnored private var microphonesRevision = 0
  /// The start in flight (`.starting`), so Cancel can end it.
  @ObservationIgnored private var startRace: StartRace?
  /// Cleanup of an abandoned start: it waits for the abandoned operation to end, then cancels what that start left open.
  /// `engine.cancel()` acts on the engine's current take, so a new start waits for this (inside its own deadline) and no intent
  /// awaits it directly: a start that never returns must not hold the panel.
  @ObservationIgnored private var cleanup: Task<Void, Never>?
  @ObservationIgnored private var following: [Task<Void, Never>] = []
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "mac-take")

  /// - Parameters:
  ///   - startDeadline: how long the engine start may take before the panel gives up.
  ///   - permissionDeadline: the same for the permission prompt, longer: a first-run user reads the dialog.
  init(
    engine: any TakeEngine, permission: any MicrophonePermission, isConfigured: @escaping () -> Bool,
    startDeadline: Duration = .seconds(15), permissionDeadline: Duration = .seconds(60)
  ) {
    self.engine = engine
    self.permission = permission
    self.isConfigured = isConfigured
    self.startDeadline = startDeadline
    self.permissionDeadline = permissionDeadline
  }

  var isVisible: Bool { phase != .idle }
  var isRecording: Bool {
    if case .recording = phase { true } else { false }
  }

  /// The running time at `date`; zero outside a take.
  func elapsed(at date: Date) -> TimeInterval {
    guard case .recording(let since) = phase else { return 0 }
    return max(date.timeIntervalSince(since), 0)
  }

  // MARK: Intents

  /// The hotkey: start a Hermes take when idle (or when a message is up), stop when recording; nothing while a start or stop
  /// runs.
  func toggle() {
    onCommand?("hotkey")
    run(mode: .hermes)
  }

  /// The popover's buttons: start a take in `mode` when idle (or when a message is up), stop when recording (either button
  /// stops the running take, whatever its mode); nothing while a start or stop runs.
  func toggle(mode: MemoMode) {
    onCommand?("panel")
    run(mode: mode)
  }

  private func run(mode: MemoMode) {
    perform { model in
      switch model.phase {
      case .idle, .failed: await model.begin(mode: mode)
      case .recording: await model.finish()
      case .starting, .stopping: break
      }
    }
  }

  /// The panel's Stop button.
  func stop() {
    onCommand?("panel")
    perform { await $0.finish() }
  }

  /// The panel's Cancel button: drops the take, abandons a start, or closes a message.
  func cancel() {
    onCommand?("panel")
    if case .failed = phase {
      phase = .idle
      return
    }
    if phase == .starting {
      // Also when the race is decided and `begin()` is finishing up: it checks the flag before showing the take.
      cancelRequested = true
      startRace?.resolve(.cancelled)
      return
    }
    perform { await $0.discard() }
  }

  /// Another microphone for the rest of the take; the segment rolls over so each file has one input.
  func select(microphone uid: String) {
    onCommand?("panel")
    // Queued, never dropped: the last pick is the one the user wants.
    enqueue { model in
      guard model.isRecording, uid != model.microphones.current?.uid else { return }
      do {
        try await model.engine.select(microphone: uid)
      } catch {
        Self.logger.error("microphone not switched: \(logDescription(of: error), privacy: .public)")
      }
      model.set(microphones: await model.engine.microphones())
    }
  }

  private func set(microphones list: Microphones) {
    microphonesRevision += 1
    microphones = list
  }

  /// Waits for the work the last intent started (tests, and the snapshot run).
  func settled() async {
    await work?.value
    await cleanup?.value
  }

  // MARK: Work

  /// One intent at a time: a press, button or switch that comes in while another is still running is dropped (a second press
  /// during the permission prompt must not stop the take it is starting). What an intent does is decided when it runs, from the
  /// phase it finds.
  private func perform(_ job: @escaping @MainActor (RecordingPanelModel) async -> Void) {
    guard !isBusy else { return }
    isBusy = true
    enqueue { model in
      defer { model.isBusy = false }
      await job(model)
    }
  }

  /// Work that must not be dropped (the recorder's failure): it runs after what is running.
  private func enqueue(_ job: @escaping @MainActor (RecordingPanelModel) async -> Void) {
    let previous = work
    work = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await job(self)
    }
  }

  private func begin(mode: MemoMode) async {
    guard isConfigured() else {
      phase = .failed(.notConfigured)
      return
    }
    cancelRequested = false
    phase = .starting
    let access = permission.access
    if access == .denied {
      phase = .failed(.microphoneDenied)
      return
    }
    let (outcome, operation) = await boundedStart(mode: mode, requestsPermission: access == .undetermined)
    switch outcome {
    case .started(let startedAt):
      // Nothing between here and `.recording` suspends: Stop and Cancel are live from the moment the take shows.
      guard !cancelRequested else { return dropStartedTake(operation) }
      level = 0
      recentLevels = []
      phase = .recording(since: startedAt)
      follow()
      loadMicrophones()
    case .failed(let failure):
      phase = .failed(failure)
    case .cancelled:
      Self.logger.info("take start cancelled")
      abandonStart(operation)
      phase = .idle
    case .timedOut:
      Self.logger.error("take not started: no answer before the deadline")
      abandonStart(operation)
      phase = .failed(.couldNotStart)
    }
  }

  /// Cancel won against a start that had already succeeded: the take is dropped through the cleanup chain (a new start waits
  /// for it), never awaited on the intent's path.
  private func dropStartedTake(_ operation: Task<Bool, Never>) {
    Self.logger.info("take start cancelled")
    abandonStart(operation)
    phase = .idle
  }

  /// The microphone list of a take that just started, off the intent's path: a call that hangs costs the list, not the take.
  /// Owned by the take (`following`), so it ends with it.
  private func loadMicrophones() {
    let engine = engine
    let revision = microphonesRevision
    following.append(
      Task { [weak self] in
        let mics = await engine.microphones()
        guard !Task.isCancelled, let self, microphonesRevision == revision else { return }
        microphones = mics
      })
  }

  /// The permission question (when open) and the engine start, raced against the deadline and Cancel. The operation runs
  /// unawaited: a call that never returns is left behind (cancelled), never waited for. It first waits for the cleanup of an
  /// earlier abandoned start, so the engine is never started while that start's late `cancel` is still to come.
  private func boundedStart(mode: MemoMode, requestsPermission: Bool) async -> (StartRace.Outcome, Task<Bool, Never>) {
    let race = StartRace()
    startRace = race
    let engine = engine
    let permission = permission
    let earlier = cleanup
    let engineDeadline = startDeadline
    race.arm(requestsPermission ? permissionDeadline : engineDeadline)
    // Reports only: whatever a start leaves open is torn down by the one owner, `abandonStart`. The result says whether the
    // engine was asked to start, i.e. whether there is anything to tear down.
    let operation = Task { @MainActor () -> Bool in
      await earlier?.value
      guard race.outcome == nil else { return false }
      if requestsPermission {
        guard await permission.request() else {
          race.resolve(.failed(.microphoneDenied))
          return false
        }
        guard race.outcome == nil else { return false }
        race.arm(engineDeadline)
      }
      do {
        race.resolve(.started(try await engine.start(mode: mode)))
      } catch {
        // A Cancel or the deadline ends the start by cancelling this task: that is not an error.
        if race.outcome == nil {
          Self.logger.error("take not started: \(logDescription(of: error), privacy: .public)")
          race.resolve(.failed(.couldNotStart))
        }
      }
      return true
    }
    let outcome = await race.wait()
    operation.cancel()
    startRace = nil
    return (outcome, operation)
  }

  /// Drops whatever the abandoned start leaves open, once it has ended (its late return included), off the intent's path.
  private func abandonStart(_ operation: Task<Bool, Never>) {
    let engine = engine
    let previous = cleanup
    cleanup = Task {
      await previous?.value
      guard await operation.value else { return }
      await engine.cancel()
    }
  }

  /// Stop: the last segment is flushed and the memo goes to the outbox.
  private func finish(after failure: Failure? = nil) async {
    guard isRecording else { return }
    phase = .stopping
    unfollow()
    do {
      switch try await engine.stop() {
      case .queued: phase = failure.map(Phase.failed) ?? .idle
      // The memo is sent, but short: say so instead of looking like a whole take.
      case .partial: phase = .failed(failure ?? .stoppedEarly)
      case .nothingRecorded: phase = .failed(failure ?? .nothingRecorded)
      }
    } catch {
      Self.logger.error("take not kept: \(logDescription(of: error), privacy: .public)")
      phase = .failed(.lost)
    }
  }

  private func discard() async {
    guard isRecording else { return }
    phase = .stopping
    unfollow()
    await engine.cancel()
    phase = .idle
  }

  /// The levels, the microphone list and the recorder's failures, until the take ends.
  private func follow() {
    unfollow()
    // Subscribed here, not inside the tasks: each take has its own subscriptions, and nothing that happens between the start and
    // the tasks' first run may be missed. They end with the take, and the next take subscribes again.
    let levels = engine.levels
    let changes = engine.microphoneChanges()
    let failures = engine.failures()
    following = [
      Task { [weak self] in
        for await value in levels {
          self?.take(level: value)
        }
      },
      Task { [weak self] in
        for await mics in changes {
          self?.set(microphones: mics)
        }
      },
      Task { [weak self] in
        for await _ in failures {
          // The recorder stopped: keep what closed before that, and say so.
          self?.enqueue { await $0.finish(after: .stoppedEarly) }
        }
      },
    ]
  }

  private func unfollow() {
    for task in following { task.cancel() }
    following = []
    level = 0
  }

  private func take(level value: Float) {
    guard isRecording else { return }
    level = value
    recentLevels.append(value)
    if recentLevels.count > Self.waveformBars { recentLevels.removeFirst(recentLevels.count - Self.waveformBars) }
  }
}

extension RecordingPanelModel.Phase {
  /// The phase's name for the device log: no time, no sentence.
  var telemetryName: String {
    switch self {
    case .idle: "idle"
    case .starting: "starting"
    case .recording: "recording"
    case .stopping: "stopping"
    case .failed: "failed"
    }
  }

  /// Which failure, as the enum case's name; `nil` outside `failed`.
  var telemetryFailure: String? {
    if case .failed(let failure) = self { failure.telemetryName } else { nil }
  }
}

/// The first answer of a start: the engine's, the deadline's or Cancel's. Later answers are ignored.
@MainActor
private final class StartRace {
  enum Outcome: Sendable {
    case started(Date)
    case failed(RecordingPanelModel.Failure)
    case cancelled
    case timedOut
  }

  private(set) var outcome: Outcome?
  private var waiter: CheckedContinuation<Outcome, Never>?
  private var timer: Task<Void, Never>?

  /// (Re)starts the deadline; the first answer, whichever it is, stops it.
  func arm(_ deadline: Duration) {
    guard outcome == nil else { return }
    timer?.cancel()
    timer = Task { [weak self] in
      guard (try? await Task.sleep(for: deadline)) != nil else { return }
      self?.resolve(.timedOut)
    }
  }

  func wait() async -> Outcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { waiter = $0 }
  }

  func resolve(_ value: Outcome) {
    guard outcome == nil else { return }
    outcome = value
    timer?.cancel()
    timer = nil
    waiter?.resume(returning: value)
    waiter = nil
  }
}
