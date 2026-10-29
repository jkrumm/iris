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

/// The Live Activity of one take, as the app sees it. Every call names the memo whose activity it is for: a take can start
/// while the previous one is still being sent, and the two activities must not touch each other. Production is ActivityKit
/// (``ActivityKitTakeLiveActivity``); the tests record the calls.
protocol TakeLiveActivity {
  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) async
  func update(memoID: String, _ state: LiveActivityContentState) async
  /// The server has the memo: the activity's push token can be registered for it (the server answers 404 before that).
  func memoCreated(memoID: String) async
  /// The memo is on the server: nothing more is sent from the device, and its pushes (`processing`, `done`, ...) carry the
  /// activity. It is not ended.
  func handOverToServer(memoID: String) async
  /// Ends the activity for good, showing `finalState` until it is dismissed.
  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async
  /// Ends every activity still in a client phase (`recording`, `paused`, `uploading`): after a relaunch nothing moves them on.
  func endClientPhaseActivities() async
}

/// Drives the Live Activity of a take the app started on its own (the start intent): recording while the take runs,
/// paused during an interruption, uploading from the stop until the outbox has sent the memo, then `processing`, from where
/// the server's pushes (registered per memo) carry it. A failure that will be retried (no network, a 5xx) keeps the
/// activity on `uploading`; a stall (a refusal the server will repeat, or out of attempts), a recorder failure and a
/// discard end it.
///
/// One follower per memo: a take that starts while the last one is still uploading does not cancel it, so the last one's
/// activity is still handed to the server. A follower that is cancelled (`stop()`) writes nothing more.
final class TakeLiveActivityCoordinator {
  private let activity: any TakeLiveActivity
  private let stack: CaptureStack
  private let created: CreatedMemoLog
  private var followers: [MemoID: Task<Void, Never>] = [:]

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
    followers[memoID]?.cancel()
    // Owned by `followers`; removes itself when the memo is settled, and `stop()` cancels the rest.
    followers[memoID] = Task {
      await follow(memoID, updates: updates, changes: changes, outbox: outbox)
      followers[memoID] = nil
    }
  }

  private func follow(
    _ memoID: MemoID, updates: AsyncStream<TakeState>, changes: AsyncStream<Void>, outbox: Outbox
  ) async {
    let id = memoID.wireID
    // Until the take ends: a snapshot of another take (or of none) means this one is over.
    for await take in updates {
      guard !Task.isCancelled, take.memoID == memoID else { break }
      switch take.phase {
      case .starting, .idle: break
      case .recording: await activity.update(memoID: id, Self.state(.recording, inputName: take.inputName))
      case .paused: await activity.update(memoID: id, Self.state(.paused, inputName: take.inputName))
      case .stopping: await activity.update(memoID: id, Self.state(.uploading, inputName: take.inputName))
      case .failed:
        // The recorder died: the take will not get better. A memo that was kept goes on in the outbox without it.
        await activity.end(memoID: id, finalState: Self.state(.failed, inputName: nil), dismissal: .later)
        return
      }
    }
    guard !Task.isCancelled else { return }
    await activity.update(memoID: id, Self.state(.uploading, inputName: nil))

    var registered = false
    if await settle(memoID, outbox: outbox, registered: &registered) { return }
    for await _ in changes {
      if await settle(memoID, outbox: outbox, registered: &registered) { return }
    }
  }

  /// Where the memo stands: still on its way (`false`), or settled (`true`): on the server and handed over, stalled and
  /// ended, or gone from the queue without ever being sent (discarded) and ended. A cancelled follower is settled and
  /// touches nothing.
  private func settle(_ memoID: MemoID, outbox: Outbox, registered: inout Bool) async -> Bool {
    guard !Task.isCancelled else { return true }
    let id = memoID.wireID
    let sent = await created.memo(id: id) != nil
    guard !Task.isCancelled else { return true }
    if sent, !registered {
      registered = true
      await activity.memoCreated(memoID: id)
    }
    guard let row = await outbox.queue().first(where: { $0.id == memoID }) else {
      guard !Task.isCancelled else { return true }
      if sent {
        await activity.update(memoID: id, Self.state(.processing, inputName: nil))
        await activity.handOverToServer(memoID: id)
      } else {
        await activity.end(memoID: id, finalState: nil, dismissal: .immediate)
      }
      return true
    }
    if case .failed(nil, _) = row.status {
      await activity.end(memoID: id, finalState: Self.state(.failed, inputName: nil), dismissal: .later)
      return true
    }
    return false  // waiting, sending, or failed with a retry coming: the outbox is still on it
  }

  /// Waits for every follower to finish (tests).
  func finished() async {
    for follower in Array(followers.values) { await follower.value }
  }

  /// Cancels every follower and waits until none can write to an activity any more.
  func stop() async {
    let running = Array(followers.values)
    followers = [:]
    for follower in running { follower.cancel() }
    for follower in running { await follower.value }
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
    private let logger = Logger(subsystem: "com.jkrumm.iris", category: "liveactivity")
    private let tokens: ActivityTokenRegistrar
    /// The activity of each take still in a client phase, by memo id: a take that starts while the last one is still being
    /// sent has its own entry. Dropped at the hand-over; the token stream and the registrar outlive it.
    private var activities: [String: Activity<MemoAttributes>] = [:]

    init(client: any APIClient) {
      tokens = ActivityTokenRegistrar(client: client)
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
        activities[memoID] = activity
        tokens.begin(memoID)
        followToken(of: activity, memoID: memoID)
      } catch {
        // The system refused (the app is not allowed to start it from here). The take goes on without it.
        logger.error("live activity not started: \(String(describing: error), privacy: .public)")
      }
    }

    func update(memoID: String, _ content: LiveActivityContentState) async {
      await activities[memoID]?.update(ActivityContent(state: content, staleDate: nil))
      await tokens.attempt(memoID)
    }

    func memoCreated(memoID: String) async {
      await tokens.memoCreated(memoID)
    }

    func handOverToServer(memoID: String) async {
      activities[memoID] = nil
      await tokens.handOver(memoID)
    }

    func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async {
      guard let activity = activities.removeValue(forKey: memoID) else { return }
      tokens.finish(memoID)
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
      for memoID in activities.keys { tokens.finish(memoID) }
      activities = [:]
    }

    /// Forwards the activity's token, now and at every rotation, until the activity ends and its stream finishes.
    private func followToken(of activity: Activity<MemoAttributes>, memoID: String) {
      // Ends with the activity's token stream.
      Task {
        for await data in activity.pushTokenUpdates {
          await tokens.setToken(memoID, data.map { String(format: "%02x", $0) }.joined())
        }
        tokens.finish(memoID)
      }
    }
  }
#endif

/// Records what the app asked of the Live Activity (`-IrisFakeCapture` and the tests): ActivityKit is never touched.
/// Every call is kept with the memo it was for.
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
  /// The memo of each entry of ``states``.
  private(set) var stateOwners: [String] = []
  private(set) var memoCreatedIDs: [String] = []
  private(set) var handedOverIDs: [String] = []
  private(set) var ends: [End] = []
  private(set) var endedIDs: [String] = []
  private(set) var orphanSweeps = 0

  func start(memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState) {
    starts.append(Start(memoID: memoID, mode: mode, startedAt: startedAt))
    record(memoID, state)
  }

  func update(memoID: String, _ state: LiveActivityContentState) { record(memoID, state) }

  func memoCreated(memoID: String) { memoCreatedIDs.append(memoID) }

  func handOverToServer(memoID: String) { handedOverIDs.append(memoID) }

  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) {
    ends.append(End(finalState: finalState, dismissal: dismissal))
    endedIDs.append(memoID)
  }

  func endClientPhaseActivities() { orphanSweeps += 1 }

  private func record(_ memoID: String, _ state: LiveActivityContentState) {
    states.append(state)
    stateOwners.append(memoID)
  }

  var memoCreatedCount: Int { memoCreatedIDs.count }
  var handedOver: Bool { !handedOverIDs.isEmpty }
  var phases: [LiveActivityPhase] { states.map(\.phase) }

  /// The phases written for one memo, in order.
  func phases(of memoID: String) -> [LiveActivityPhase] {
    zip(stateOwners, states).filter { $0.0 == memoID }.map { $0.1.phase }
  }

  /// Some activity was ended for good (not handed to the server).
  var ended: Bool { !ends.isEmpty }
}
