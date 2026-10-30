import Foundation
import IrisCapture
import IrisCore
import Observation
import os

/// What the take screen, the banner and the record button show: the one take in progress and what can be done with it. The
/// take itself is the capture session's; this follows its updates.
///
/// A take bound to a thread (a voice reply from the thread screen) has its own hold-to-talk control and does not show up
/// here.
@MainActor
@Observable
final class TakeModel {
  /// How many bars of the level history the take screen draws.
  static let levelBars = 44

  private(set) var state = TakeState.idle
  private(set) var levels = [Float](repeating: 0.08, count: TakeModel.levelBars)
  /// The microphones the take can use, refreshed when the picker opens.
  private(set) var inputs: [InputPort] = []
  /// Memos still on their way up (typed, voiced or replies), not counting the take being recorded.
  private(set) var sending = 0
  /// A start, stop or cancel that did not go through, in words for the user.
  var failure: String?
  /// The full take screen is up (otherwise a running take shows as the banner).
  var showsFull = false
  var showsInputPicker = false
  /// The mode picker of the record control (a long press) is up.
  var showsModePicker = false
  private(set) var isEnding = false
  private var pausedAt: Date?
  private var pausedTotal: TimeInterval = 0
  private var currentMemo: MemoID?

  private let controller: TakeController
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "take")

  init(controller: TakeController) {
    self.controller = controller
  }

  // MARK: What the views read

  /// A take of this screen is in progress (anything between the start and the end, a failed recorder included).
  var isActive: Bool { state.phase != .idle && state.request?.threadID == nil }

  var isPaused: Bool { state.phase == .paused }

  /// Any take holds the microphone (starting, recording, paused or stopping), a thread's hold-to-talk included, unlike
  /// ``isActive``. A spoken reply waits for it.
  var isCapturing: Bool {
    switch state.phase {
    case .starting, .recording, .paused, .stopping: true
    case .idle, .failed: false
    }
  }

  /// Whether a new take can start (a server is saved, a recorder exists, none runs).
  var canStart: Bool { controller.canStart && state.phase == .idle }

  /// The instant the timer counts from: the take's start moved forward by what was paused.
  var timerStart: Date? { state.startedAt?.addingTimeInterval(pausedTotal) }

  /// Where the timer stands still while the take is paused.
  var timerFrozenAt: Date? { isPaused ? pausedAt : nil }

  var modeTitle: String {
    (state.request.flatMap { MemoMode(rawValue: $0.mode) } ?? .auto).composerTitle
  }

  var inputName: String? { state.inputName }

  /// The banner's second line: what else is on its way.
  var sendingText: String? {
    sending > 0 ? String(localized: "\(sending) sending", comment: "Take banner: memos still being sent") : nil
  }

  var screenNotice: String? {
    guard state.phase == .failed else { return nil }
    guard let reason = state.failure else {
      return String(localized: "The recorder stopped.", comment: "Take screen notice")
    }
    return String(localized: "The recorder stopped: \(reason)", comment: "Take screen notice")
  }

  // MARK: Following the take

  /// Follows the session and the queue until the task is cancelled. Started once by the root view.
  func run() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.followState() }
      group.addTask { await self.followLevels() }
      group.addTask { await self.followQueue() }
    }
  }

  private func followState() async {
    guard let updates = await controller.updates() else { return }
    for await take in updates { apply(take) }
  }

  private func followLevels() async {
    guard let stream = await controller.levels() else { return }
    for await level in stream where state.phase == .recording {
      levels.removeFirst()
      levels.append(min(max(level, 0.08), 1))
    }
  }

  private func followQueue() async {
    await refreshQueue()
    for await _ in await controller.queueChanges() { await refreshQueue() }
  }

  private func refreshQueue() async {
    sending = await controller.queuedItems().count { item in
      switch item.state {
      case .waiting, .sending: item.kind != .removal
      case .recording, .failed: false
      }
    }
  }

  func apply(_ take: TakeState) {
    if take.memoID != currentMemo {
      currentMemo = take.memoID
      pausedAt = nil
      pausedTotal = 0
      levels = [Float](repeating: 0.08, count: Self.levelBars)
      // A take opens on the full screen; the banner is what it becomes when the user browses on.
      if take.phase != .idle, take.request?.threadID == nil { showsFull = true }
    }
    if take.phase == .paused, pausedAt == nil {
      pausedAt = Date()
    } else if take.phase != .paused, let pausedAt {
      pausedTotal += Date().timeIntervalSince(pausedAt)
      self.pausedAt = nil
    }
    state = take
    if take.phase == .idle {
      showsFull = false
      showsInputPicker = false
    }
  }

  // MARK: Actions

  func start(mode: MemoMode = .auto) async {
    guard canStart else { return }
    failure = nil
    do {
      try await controller.start(mode: mode)
    } catch let error as StartMemoError {
      failure = String(localized: error.localizedStringResource)
    } catch {
      logger.error("take not started: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Iris could not start recording.", comment: "Take failure")
    }
  }

  /// Ends the take and sends it.
  func stop() async {
    guard isActive, !isEnding else { return }
    isEnding = true
    defer { isEnding = false }
    do {
      if try await controller.stop() == nil {
        failure = String(localized: "Nothing was recorded.", comment: "Take failure")
      }
    } catch CaptureError.recordingFailed(let reason) {
      logger.error("take lost, the recorder failed: \(reason, privacy: .public)")
      failure = String(localized: "The recording failed, so nothing was kept.", comment: "Take failure")
    } catch {
      logger.error("take not stopped: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Iris could not stop the recording.", comment: "Take failure")
    }
  }

  /// Drops the take; nothing is sent, and the server is told to delete a memo it already created.
  func discard() async {
    guard isActive, !isEnding else { return }
    isEnding = true
    defer { isEnding = false }
    do {
      try await controller.cancel()
    } catch {
      logger.error("take not discarded: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Iris could not discard the recording.", comment: "Take failure")
    }
  }

  func togglePause() async {
    guard state.phase == .recording || state.phase == .paused else { return }
    await controller.togglePause()
  }

  func openInputPicker() async {
    inputs = await controller.route().availableInputs
    showsInputPicker = true
  }

  func pickInput(_ port: InputPort) async {
    showsInputPicker = false
    do {
      try await controller.switchInput(to: port.uid)
    } catch {
      logger.error("input not switched: \(String(describing: error), privacy: .public)")
      failure = String(localized: "Could not switch the microphone.", comment: "Take failure")
    }
  }
}
