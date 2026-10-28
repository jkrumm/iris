import Foundation
import IrisCapture
import IrisCore

/// The Live Activity of one take, as the app sees it. Production is ActivityKit (``ActivityKitTakeLiveActivity``); the
/// tests record the calls.
protocol TakeLiveActivity {
  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) async
  func update(_ state: LiveActivityContentState) async
  /// Leaves the activity to the server's pushes (`processing`, `done`, ...): nothing more is sent from the device.
  func end() async
}

/// Drives the Live Activity of a take the app started on its own (the start intent): recording while the take runs,
/// paused during an interruption, uploading from the stop until the outbox has sent the memo, then `processing`.
/// From there the server's pushes (registered per memo) carry it.
final class TakeLiveActivityCoordinator {
  private let activity: any TakeLiveActivity
  private let stack: CaptureStack
  private var follower: Task<Void, Never>?

  init(activity: any TakeLiveActivity, stack: CaptureStack) {
    self.activity = activity
    self.stack = stack
  }

  /// Requests the activity for the take that just started and follows it until the memo is sent.
  func begin(memoID: MemoID, mode: MemoMode, startedAt: Date) async {
    await activity.start(
      memoID: memoID.wireID, mode: mode, startedAt: startedAt, state: Self.state(.recording, inputName: nil))
    let session = await stack.session()
    let outbox = await stack.outbox()
    let updates = await session.updates()
    let changes = await outbox.changes()
    follower?.cancel()
    // Owned by `follower`; replaced by the next take and cancelled by `stop()`.
    follower = Task { [activity] in
      for await take in updates where take.memoID == memoID || take.phase == .idle {
        switch take.phase {
        case .recording: await activity.update(Self.state(.recording, inputName: take.inputName))
        case .paused: await activity.update(Self.state(.paused, inputName: take.inputName))
        case .stopping: await activity.update(Self.state(.uploading, inputName: take.inputName))
        case .idle: break
        }
        if take.phase == .idle { break }
      }
      await activity.update(Self.state(.uploading, inputName: nil))
      for await _ in changes {
        let row = await outbox.queue().first { $0.id == memoID }
        guard let row else { break }
        if case .failed = row.status { return }
      }
      await activity.update(Self.state(.processing, inputName: nil))
      await activity.end()
    }
  }

  /// Waits for the follower to finish (tests).
  func finished() async {
    await follower?.value
  }

  func stop() {
    follower?.cancel()
    follower = nil
  }

  static func state(_ phase: LiveActivityPhase, inputName: String?) -> LiveActivityContentState {
    LiveActivityContentState(phase: phase, hasReply: false, inputName: inputName)
  }
}

#if canImport(ActivityKit) && !os(macOS)
  // `Activity` is not `Sendable` and its `update` is nonisolated: the instance never leaves the main actor except
  // into that call, which ActivityKit documents as safe from any context.
  @preconcurrency import ActivityKit

  /// ActivityKit behind the port. The push token of the activity goes to the server per memo, so its pushes reach it
  /// once the app is suspended. Not verified on a device (rendered nowhere yet: `docs/spikes/device-checklist.md`).
  /// Main-actor bound (the default isolation of the app), because `Activity` is not `Sendable`.
  final class ActivityKitTakeLiveActivity: TakeLiveActivity {
    private let client: any APIClient
    private var activity: Activity<MemoAttributes>?

    init(client: any APIClient) {
      self.client = client
    }

    func start(memoID: String, mode: MemoMode, startedAt: Date, state content: LiveActivityContentState) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let attributes = MemoAttributes(memoId: memoID, mode: mode, startedAt: startedAt)
      let activityContent = ActivityContent(state: content, staleDate: nil)
      do {
        let activity: Activity<MemoAttributes>
        do {
          activity = try Activity.request(attributes: attributes, content: activityContent, pushType: .token)
        } catch {
          // No push entitlement (an unsigned simulator build): the local activity still shows the take.
          activity = try Activity.request(attributes: attributes, content: activityContent, pushType: nil)
        }
        self.activity = activity
        registerToken(of: activity, memoID: memoID)
      } catch {
        // The system refused (the app is not allowed to start it from here). The take goes on without it.
        activity = nil
      }
    }

    func update(_ content: LiveActivityContentState) async {
      await activity?.update(ActivityContent(state: content, staleDate: nil))
    }

    func end() async {
      activity = nil
    }

    private func registerToken(of activity: Activity<MemoAttributes>, memoID: String) {
      let client = client
      // Ends with the activity's token stream.
      Task {
        for await token in activity.pushTokenUpdates {
          let hex = token.map { String(format: "%02x", $0) }.joined()
          try? await client.setActivityToken(memoID: memoID, request: ActivityTokenRequest(token: hex))
        }
      }
    }
  }
#endif

/// Records what the app asked of the Live Activity (`-IrisFakeCapture` and the tests): ActivityKit is never touched.
final class RecordingLiveActivity: TakeLiveActivity {
  struct Start: Equatable, Sendable {
    let memoID: String
    let mode: MemoMode
    let startedAt: Date
  }

  private(set) var starts: [Start] = []
  private(set) var states: [LiveActivityContentState] = []
  private(set) var ended = false

  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) {
    starts.append(Start(memoID: memoID, mode: mode, startedAt: startedAt))
    states.append(state)
  }

  func update(_ state: LiveActivityContentState) { states.append(state) }

  func end() { ended = true }

  var phases: [LiveActivityPhase] { states.map(\.phase) }
}
