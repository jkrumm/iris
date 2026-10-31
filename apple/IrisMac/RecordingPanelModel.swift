import Foundation
import IrisCapture
import Observation
import os

/// The state machine behind the floating recording panel: what a take on the Mac looks like from the hotkey and the panel's
/// buttons. It decides nothing about audio; the ``TakeEngine`` does, so every path here runs on fakes.
///
/// ```
/// idle ── toggle ──▶ starting ──▶ recording ── toggle / Stop ──▶ stopping ──▶ idle
///   ▲                   │             │ Cancel ───────────────────────────────▶ idle
///   └── dismiss ◀── failed ◀──────────┴── engine failed (partial take is kept) / start refused / stop lost the audio
/// ```
///
/// Presses and buttons are ignored while a start or a stop is running; the panel shows whenever the phase is not `idle`.
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

  static let waveformBars = 36

  @ObservationIgnored private let engine: any TakeEngine
  @ObservationIgnored private let permission: any MicrophonePermission
  @ObservationIgnored private let isConfigured: () -> Bool
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var isBusy = false
  @ObservationIgnored private var following: [Task<Void, Never>] = []
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "mac-take")

  init(engine: any TakeEngine, permission: any MicrophonePermission, isConfigured: @escaping () -> Bool) {
    self.engine = engine
    self.permission = permission
    self.isConfigured = isConfigured
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

  /// The hotkey: start when idle (or when a message is up), stop when recording; nothing while a start or stop runs.
  func toggle() {
    onCommand?("hotkey")
    perform { model in
      switch model.phase {
      case .idle, .failed: await model.begin()
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

  /// The panel's Cancel button: drops the take, or closes a message.
  func cancel() {
    onCommand?("panel")
    if case .failed = phase {
      phase = .idle
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
      model.microphones = await model.engine.microphones()
    }
  }

  /// Waits for the work the last intent started (tests, and the snapshot run).
  func settled() async {
    await work?.value
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

  private func begin() async {
    guard isConfigured() else {
      phase = .failed(.notConfigured)
      return
    }
    phase = .starting
    switch permission.access {
    case .denied:
      phase = .failed(.microphoneDenied)
      return
    case .undetermined:
      guard await permission.request() else {
        phase = .failed(.microphoneDenied)
        return
      }
    case .granted:
      break
    }
    do {
      let startedAt = try await engine.start()
      level = 0
      recentLevels = []
      microphones = await engine.microphones()
      phase = .recording(since: startedAt)
      follow()
    } catch {
      Self.logger.error("take not started: \(logDescription(of: error), privacy: .public)")
      phase = .failed(.couldNotStart)
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
          self?.microphones = mics
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
