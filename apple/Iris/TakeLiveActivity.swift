import Foundation
import IrisCapture
import IrisCore
import os

/// How long a finished Live Activity stays on the Lock Screen after the app ended it.
nonisolated enum ActivityDismissal: Equatable, Sendable {
  case immediate
  /// The same 15 minutes the server's `end` push uses.
  case later
}

/// The Live Activity of one take, as the app sees it. Production is ActivityKit (``ActivityKitTakeLiveActivity``); the
/// tests record the calls.
protocol TakeLiveActivity {
  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) async
  func update(_ state: LiveActivityContentState) async
  /// The server has the memo: the activity's push token can be registered for it (the server answers 404 before that).
  func memoCreated() async
  /// The memo is on the server: nothing more is sent from the device, and its pushes (`processing`, `done`, ...) carry the
  /// activity. It is not ended.
  func handOverToServer() async
  /// Ends the activity for good, showing `finalState` until it is dismissed.
  func end(finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async
  /// Ends every activity still in a client phase (`recording`, `paused`, `uploading`): after a relaunch nothing moves them on.
  func endClientPhaseActivities() async
}

/// Drives the Live Activity of a take the app started on its own (the start intent): recording while the take runs,
/// paused during an interruption, uploading from the stop until the outbox has sent the memo, then `processing`, from where
/// the server's pushes (registered per memo) carry it. A failure that will be retried (no network, a 5xx) keeps the
/// activity on `uploading`; a stall (a refusal the server will repeat, or out of attempts) and a discard end it.
final class TakeLiveActivityCoordinator {
  private let activity: any TakeLiveActivity
  private let stack: CaptureStack
  private let created: CreatedMemoLog
  private var follower: Task<Void, Never>?

  init(activity: any TakeLiveActivity, stack: CaptureStack, created: CreatedMemoLog) {
    self.activity = activity
    self.stack = stack
    self.created = created
  }

  /// Requests the activity for the take that just started and follows it until the memo is sent.
  func begin(memoID: MemoID, mode: MemoMode, startedAt: Date) async {
    await activity.start(
      memoID: memoID.wireID, mode: mode, startedAt: startedAt, state: Self.state(.recording, inputName: nil))
    guard let session = try? await stack.session(), let outbox = try? await stack.outbox() else { return }
    let updates = await session.updates()
    let changes = await outbox.changes()
    follower?.cancel()
    // Owned by `follower`; replaced by the next take and cancelled by `stop()`.
    follower = Task {
      for await take in updates where take.memoID == memoID || take.phase == .idle {
        switch take.phase {
        case .starting, .idle: break
        case .recording: await activity.update(Self.state(.recording, inputName: take.inputName))
        case .paused: await activity.update(Self.state(.paused, inputName: take.inputName))
        case .stopping: await activity.update(Self.state(.uploading, inputName: take.inputName))
        }
        if take.phase == .idle { break }
      }
      await activity.update(Self.state(.uploading, inputName: nil))

      var registered = false
      if await settle(memoID, outbox: outbox, registered: &registered) { return }
      for await _ in changes {
        if await settle(memoID, outbox: outbox, registered: &registered) { return }
      }
    }
  }

  /// Where the memo stands: still on its way (`false`), or settled (`true`): on the server and handed over, stalled and
  /// ended, or gone from the queue without ever being sent (discarded) and ended.
  private func settle(_ memoID: MemoID, outbox: Outbox, registered: inout Bool) async -> Bool {
    let sent = await created.memo(id: memoID.wireID) != nil
    if sent, !registered {
      registered = true
      await activity.memoCreated()
    }
    guard let row = await outbox.queue().first(where: { $0.id == memoID }) else {
      if sent {
        await activity.update(Self.state(.processing, inputName: nil))
        await activity.handOverToServer()
      } else {
        await activity.end(finalState: nil, dismissal: .immediate)
      }
      return true
    }
    if case .failed(nil, _) = row.status {
      await activity.end(finalState: Self.state(.failed, inputName: nil), dismissal: .later)
      return true
    }
    return false  // waiting, sending, or failed with a retry coming: the outbox is still on it
  }

  /// Waits for the follower to finish (tests).
  func finished() async {
    await follower?.value
  }

  func stop() {
    follower?.cancel()
    follower = nil
  }

  /// At launch: a take's activity does not outlive the process that ran it (its memo goes on in the outbox).
  func endOrphans() async {
    await activity.endClientPhaseActivities()
  }

  static func state(_ phase: LiveActivityPhase, inputName: String?) -> LiveActivityContentState {
    LiveActivityContentState(phase: phase, hasReply: false, inputName: inputName)
  }
}

#if canImport(ActivityKit) && !os(macOS)
  // `Activity` is not `Sendable` and its `update` is nonisolated: the instance never leaves the main actor except
  // into that call, which ActivityKit documents as safe from any context.
  @preconcurrency import ActivityKit

  /// ActivityKit behind the port. The activity's push token goes to the server once it knows the memo, so its pushes reach
  /// the activity after the app is suspended. Not verified on a device (rendered nowhere yet: `docs/spikes/device-checklist.md`).
  /// Main-actor bound (the default isolation of the app), because `Activity` is not `Sendable`.
  final class ActivityKitTakeLiveActivity: TakeLiveActivity {
    private let client: any APIClient
    private let logger = Logger(subsystem: "com.jkrumm.iris", category: "liveactivity")
    private var activity: Activity<MemoAttributes>?
    private var token: String?
    private var memoExists = false
    private var registeredToken: String?

    init(client: any APIClient) {
      self.client = client
    }

    func start(memoID: String, mode: MemoMode, startedAt: Date, state content: LiveActivityContentState) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let attributes = MemoAttributes(memoId: memoID, mode: mode, startedAt: startedAt)
      let activityContent = ActivityContent(state: content, staleDate: nil)
      token = nil
      memoExists = false
      registeredToken = nil
      do {
        let activity: Activity<MemoAttributes>
        do {
          activity = try Activity.request(attributes: attributes, content: activityContent, pushType: .token)
        } catch {
          // No push entitlement (an unsigned simulator build): the local activity still shows the take.
          activity = try Activity.request(attributes: attributes, content: activityContent, pushType: nil)
        }
        self.activity = activity
        followToken(of: activity)
      } catch {
        // The system refused (the app is not allowed to start it from here). The take goes on without it.
        logger.error("live activity not started: \(String(describing: error), privacy: .public)")
        activity = nil
      }
    }

    func update(_ content: LiveActivityContentState) async {
      await activity?.update(ActivityContent(state: content, staleDate: nil))
      await registerTokenIfPossible()
    }

    func memoCreated() async {
      memoExists = true
      await registerTokenIfPossible()
    }

    func handOverToServer() async {
      await registerTokenIfPossible()
      activity = nil
    }

    func end(finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async {
      guard let activity else { return }
      self.activity = nil
      let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
      let policy: ActivityUIDismissalPolicy =
        switch dismissal {
        case .immediate: .immediate
        case .later: .after(Date().addingTimeInterval(15 * 60))
        }
      await activity.end(content, dismissalPolicy: policy)
    }

    func endClientPhaseActivities() async {
      for orphan in Activity<MemoAttributes>.activities where orphan.content.state.phase.isClientPhase {
        await orphan.end(nil, dismissalPolicy: .immediate)
      }
      activity = nil
    }

    /// Keeps the latest token; it is sent once the server knows the memo, and again when the token rotates.
    private func followToken(of activity: Activity<MemoAttributes>) {
      // Ends with the activity's token stream.
      Task {
        for await data in activity.pushTokenUpdates {
          token = data.map { String(format: "%02x", $0) }.joined()
          await registerTokenIfPossible()
        }
      }
    }

    /// `PUT /memos/:id/activity-token`, only for a memo the server has and a token it has not seen; a failure is logged and
    /// tried again on the next update or token change.
    private func registerTokenIfPossible() async {
      guard let activity, memoExists, let token, token != registeredToken else { return }
      do {
        try await client.setActivityToken(
          memoID: activity.attributes.memoId, request: ActivityTokenRequest(token: token))
        registeredToken = token
      } catch {
        logger.error("activity token not registered: \(String(describing: error), privacy: .public)")
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

  struct End: Equatable, Sendable {
    let finalState: LiveActivityContentState?
    let dismissal: ActivityDismissal
  }

  private(set) var starts: [Start] = []
  private(set) var states: [LiveActivityContentState] = []
  private(set) var memoCreatedCount = 0
  private(set) var handedOver = false
  private(set) var ends: [End] = []
  private(set) var orphanSweeps = 0

  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) {
    starts.append(Start(memoID: memoID, mode: mode, startedAt: startedAt))
    states.append(state)
  }

  func update(_ state: LiveActivityContentState) { states.append(state) }

  func memoCreated() { memoCreatedCount += 1 }

  func handOverToServer() { handedOver = true }

  func end(finalState: LiveActivityContentState?, dismissal: ActivityDismissal) {
    ends.append(End(finalState: finalState, dismissal: dismissal))
  }

  func endClientPhaseActivities() { orphanSweeps += 1 }

  var phases: [LiveActivityPhase] { states.map(\.phase) }

  /// The activity was ended for good (not handed to the server).
  var ended: Bool { !ends.isEmpty }
}
