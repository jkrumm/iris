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
  /// activity. It is not ended. Without a push token (a Personal Team build, remote updates off) nothing will ever move it
  /// on, so the activity follows the memo itself and ends once the server is done with it.
  func handOverToServer(memoID: String) async
  /// Ends the activity for good, showing `finalState` until it is dismissed.
  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async
  /// Ends every activity still in a client phase (`recording`, `paused`, `uploading`) except those of `memoIDs`, the takes this
  /// process is driving: after a relaunch nothing moves the others on, but a take that runs now must keep its activity.
  func endClientPhaseActivities(except memoIDs: Set<String>) async
  /// Ends the handed-over activities of earlier runs that have outlived their use (``StaleActivityRule``).
  func endStaleActivities() async
}

/// A Live Activity the app handed to the server (any phase after `uploading`), as the stale rules see it.
nonisolated struct HandedOverActivity: Equatable, Sendable {
  let memoID: String
  let phase: LiveActivityPhase
  let startedAt: Date
  /// A push token exists: the server's pushes move it on and end it. Without one only the device can.
  let remoteUpdates: Bool
  /// The server the memo lives on (``MemoAttributes/serverKey``); nil for an activity that predates the field.
  var serverKey: String?
}

/// When a handed-over Live Activity must go. Without APNs (a Personal Team build) the server's `end` push never arrives,
/// so a `processing` activity stays on the Lock Screen and in the Dynamic Island for ever (up to 8 hours) and hides the
/// controls of the take that is running.
nonisolated enum StaleActivityRule {
  /// An activity this old is stale whatever the memo says (the server's `end` push is 15 minutes after done).
  static let maxAge: TimeInterval = 60 * 60

  enum Verdict: Equatable {
    case keep
    /// End it now; `final` is what it shows until dismissed (`nil`: nothing, it just goes).
    case end(final: LiveActivityContentState?)
  }

  /// What to do with an activity found on launch (or while following one) given what the server says about its memo.
  /// `memo` is `nil` while the server could not be asked; `gone` is a 404 (deleted, or never created).
  static func verdict(
    for activity: HandedOverActivity, memo: Memo?, gone: Bool = false, now: Date
  ) -> Verdict {
    if gone || now.timeIntervalSince(activity.startedAt) > maxAge { return .end(final: nil) }
    // With pushes the server owns the activity (its `end` carries the result and the dismissal).
    guard !activity.remoteUpdates, let memo, memo.state.isResultReady else { return .keep }
    return .end(final: finalState(of: memo))
  }

  /// The result an activity without pushes ends on.
  static func finalState(of memo: Memo) -> LiveActivityContentState {
    switch memo.state {
    case .failed: LiveActivityContentState(phase: .failed, hasReply: false)
    case .needsRoute: LiveActivityContentState(phase: .needsRoute, hasReply: false)
    default: LiveActivityContentState(phase: .done, hasReply: memo.hasReply && !memo.isDeleted)
    }
  }

  /// A starting take takes the island: finished activities go, and so do the ones nothing will ever update. An activity the
  /// server still drives (a push token, not finished) stays: it ends itself in a moment.
  static func yieldsToNewTake(_ activity: HandedOverActivity) -> Bool {
    switch activity.phase {
    case .done, .failed: true
    case .processing, .needsRoute: !activity.remoteUpdates
    case .recording, .paused, .uploading: false
    }
  }
}

/// The activities of the platform as ``StaleActivitySweeper`` sees them. ActivityKit is the production adapter.
protocol ActivityCatalog {
  /// Every live activity that is not in a client phase.
  func handedOverActivities() -> [HandedOverActivity]
  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async
}

/// Ends the Live Activities nothing else will end: when a take starts, at launch, and when the memo of one finishes while
/// the app runs.
struct StaleActivitySweeper {
  let catalog: any ActivityCatalog
  let client: any APIClient
  /// The server `client` talks to right now; an activity of another server is not asked about (this one knows nothing of its
  /// memo, and its 404 would end a valid activity) and ends by age alone. `nil` weighs no activity as foreign.
  let serverKey: @Sendable () -> String?
  let now: @Sendable () -> Date
  let sleep: @Sendable (Duration) async throws -> Void
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "liveactivity")

  init(
    catalog: any ActivityCatalog, client: any APIClient, serverKey: @escaping @Sendable () -> String? = { nil },
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.catalog = catalog
    self.client = client
    self.serverKey = serverKey
    self.now = now
    self.sleep = sleep
  }

  /// A take is about to request its activity: it must own the island.
  func makeRoomForTake() async {
    for activity in catalog.handedOverActivities() where StaleActivityRule.yieldsToNewTake(activity) {
      logger.info("ending activity \(activity.memoID, privacy: .public): a take is starting")
      await catalog.end(memoID: activity.memoID, finalState: nil, dismissal: .immediate)
    }
  }

  /// Launch: asks the server about every handed-over activity and ends the ones the rule names. Returns the memos of the
  /// activities it kept that have no push token: nothing will ever move those on, so the caller follows them (``follow(memoID:)``).
  func sweep() async -> [String] {
    let activities = catalog.handedOverActivities()
    // One lookup per activity, all at once: a launch with several handed-over activities waits for the slowest, not the sum.
    let looked = await withTaskGroup(of: (Int, Memo?, Bool).self) { group in
      for (index, activity) in activities.enumerated() {
        group.addTask {
          let (memo, gone) = await lookup(activity)
          return (index, memo, gone)
        }
      }
      var answers: [Int: (Memo?, Bool)] = [:]
      for await (index, memo, gone) in group { answers[index] = (memo, gone) }
      return answers
    }
    var toFollow: [String] = []
    for (index, activity) in activities.enumerated() {
      let (memo, gone) = looked[index] ?? (nil, false)
      guard case .end(let final) = StaleActivityRule.verdict(for: activity, memo: memo, gone: gone, now: now()) else {
        if !activity.remoteUpdates { toFollow.append(activity.memoID) }
        continue
      }
      logger.info(
        "ending activity \(activity.memoID, privacy: .public) at launch: \(Self.reason(final: final, gone: gone), privacy: .public)"
      )
      await catalog.end(memoID: activity.memoID, finalState: final, dismissal: .immediate)
    }
    return toFollow
  }

  /// Polls the memo of an activity until the server is done with it (or the activity is too old), then ends it on the result
  /// for a while, as the server's `end` push would. A push token that shows up later hands the activity back to the server.
  /// Returns when the activity is gone or ended, and ends nothing once cancelled (the activity was ended by someone else).
  func follow(memoID: String) async {
    var delay = Duration.seconds(3)
    while !Task.isCancelled {
      guard let activity = catalog.handedOverActivities().first(where: { $0.memoID == memoID }) else { return }
      let (memo, gone) = await lookup(activity)
      guard !Task.isCancelled else { return }
      if case .end(let final) = StaleActivityRule.verdict(for: activity, memo: memo, gone: gone, now: now()) {
        logger.info(
          "ending activity \(activity.memoID, privacy: .public): \(Self.reason(final: final, gone: gone), privacy: .public)"
        )
        await catalog.end(memoID: activity.memoID, finalState: final, dismissal: final == nil ? .immediate : .later)
        return
      }
      guard (try? await sleep(delay)) != nil else { return }
      delay = min(delay * 2, .seconds(30))
    }
  }

  private static func reason(final: LiveActivityContentState?, gone: Bool) -> String {
    if gone { return "the server has no such memo" }
    guard let final else { return "older than \(Int(StaleActivityRule.maxAge)) s" }
    return "the memo is \(final.phase.rawValue)"
  }

  private func lookup(_ activity: HandedOverActivity) async -> (memo: Memo?, gone: Bool) {
    if let own = serverKey(), let origin = activity.serverKey, own != origin { return (nil, false) }
    let memoID = activity.memoID
    do {
      return (try await client.memo(id: memoID).memo, false)
    } catch let error as APIError {
      if case .server(404, _) = error { return (nil, true) }
      logger.error("activity memo lookup failed: \(String(describing: error), privacy: .public)")
      return (nil, false)
    } catch is CancellationError {
      return (nil, false)
    } catch {
      logger.error("activity memo lookup failed: \(String(describing: error), privacy: .public)")
      return (nil, false)
    }
  }
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
  /// Takes this process started whose activity has not settled: from the request of the activity until its follower is done.
  private var live: Set<MemoID> = []

  init(activity: any TakeLiveActivity, stack: CaptureStack, created: CreatedMemoLog) {
    self.activity = activity
    self.stack = stack
    self.created = created
  }

  /// Requests the activity for the take that just started and follows it until the memo is sent.
  func begin(memoID: MemoID, mode: MemoMode, startedAt: Date) async {
    live.insert(memoID)
    await activity.start(
      memoID: memoID.wireID, mode: mode, startedAt: startedAt,
      state: Self.state(.recording, inputName: nil, note: otherMemosNote(besides: memoID)))
    guard let session = try? await stack.session(), let outbox = try? await stack.outbox() else {
      live.remove(memoID)
      return
    }
    let updates = await session.updates()
    let changes = await outbox.changes()
    followers[memoID]?.cancel()
    // Owned by `followers`; removes itself when the memo is settled, and `stop()` cancels the rest.
    followers[memoID] = Task {
      await follow(memoID, updates: updates, changes: changes, outbox: outbox)
      followers[memoID] = nil
      live.remove(memoID)
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
      case .recording:
        await activity.update(
          memoID: id, Self.state(.recording, inputName: take.inputName, note: otherMemosNote(besides: memoID)))
      case .paused:
        await activity.update(
          memoID: id, Self.state(.paused, inputName: take.inputName, note: otherMemosNote(besides: memoID)))
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
    // A queued `DELETE` of the discarded take is not the take: the activity does not wait for it.
    guard let row = await outbox.queue().first(where: { $0.id == memoID && !$0.isDeletion }) else {
      guard !Task.isCancelled else { return true }
      // The row also leaves the queue when the take was discarded: its memo is being deleted, there is nothing to hand over.
      if sent, await !outbox.wasDiscarded(memoID) {
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
    live = []
    for follower in running { follower.cancel() }
    for follower in running { await follower.value }
  }

  /// A take's activity does not outlive the process that ran it (its memo goes on in the outbox), so the activities left in a
  /// client phase by an earlier run are ended. Safe to call whenever the connection changes: the takes this process is
  /// recording or sending keep theirs.
  func endOrphans() async {
    await activity.endClientPhaseActivities(except: Set(live.map(\.wireID)))
    await activity.endStaleActivities()
  }

  /// The state of a client phase. `note` rides in `headline` (a short line about another memo still being sent, well under
  /// the 60 characters, never transcript or reply text); the widget shows it as a note while the take records.
  static func state(_ phase: LiveActivityPhase, inputName: String?, note: String? = nil) -> LiveActivityContentState {
    LiveActivityContentState(phase: phase, headline: note, hasReply: false, inputName: inputName)
  }

  /// "1 earlier memo is still sending" while other memos of this run are still on their way up, so the activity of a new
  /// take explains the queue behind it. `nil` when there is none.
  private func otherMemosNote(besides memoID: MemoID) -> String? {
    let others = followers.keys.count { $0 != memoID }
    switch others {
    case 0: return nil
    case 1: return String(localized: "1 earlier memo is still sending", comment: "Live Activity note")
    default: return String(localized: "\(others) earlier memos are still sending", comment: "Live Activity note")
    }
  }
}

#if canImport(ActivityKit) && !os(macOS)
  // `Activity` is not `Sendable` and its `update` is nonisolated: the instance never leaves the main actor except
  // into that call, which ActivityKit documents as safe from any context.
  @preconcurrency import ActivityKit

  /// ActivityKit behind the port. The activity's push token goes to the server once it knows the memo, so its pushes reach
  /// the activity after the app is suspended. Not verified on a device (rendered nowhere yet: `docs/spikes/device-checklist.md`).
  /// Main-actor bound (the default isolation of the app), because `Activity` is not `Sendable`.
  final class ActivityKitTakeLiveActivity: TakeLiveActivity, ActivityCatalog {
    private let logger = Logger(subsystem: "com.jkrumm.iris", category: "liveactivity")
    private let tokens: ActivityTokenRegistrar
    /// The activity of each take still in a client phase, by memo id: a take that starts while the last one is still being
    /// sent has its own entry. Dropped at the hand-over; the token stream and the registrar outlive it.
    private var activities: [String: Activity<MemoAttributes>] = [:]
    private let client: any APIClient
    /// The key of the server the app talks to now (``ConnectionCredentials/serverKey``); nil without a saved connection.
    private let serverKey: @Sendable () -> String?
    /// Built per use: the catalog is this object.
    private var sweeper: StaleActivitySweeper {
      StaleActivitySweeper(catalog: self, client: client, serverKey: serverKey)
    }
    /// The sweep in progress: a second ask (launch and a connection change, foregrounding) joins it instead of running twice.
    private var sweeping: Task<Void, Never>?
    /// The poll that ends a handed-over activity without a push token once its memo is finished, by memo id.
    private var followers: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(client: any APIClient, serverKey: @escaping @Sendable () -> String? = { nil }) {
      self.client = client
      self.serverKey = serverKey
      tokens = ActivityTokenRegistrar(client: client)
    }

    func start(memoID: String, mode: MemoMode, startedAt: Date, state content: LiveActivityContentState) async {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      // The island shows one activity: the running take's wins over finished ones and over ones nothing will update.
      await sweeper.makeRoomForTake()
      let attributes = MemoAttributes(memoId: memoID, mode: mode, startedAt: startedAt, serverKey: serverKey())
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
      let hasToken = activities.removeValue(forKey: memoID)?.pushToken != nil
      await tokens.handOver(memoID)
      guard !hasToken else { return }
      follow(memoID)
    }

    /// No push token: the server's `end` never arrives, so this process ends the activity when the memo is finished.
    private func follow(_ memoID: String) {
      guard followers[memoID] == nil else { return }
      let id = UUID()
      // Owned by `followers`; `end` cancels it. It removes its own entry, never a newer follower's.
      let task = Task { [sweeper] in
        await sweeper.follow(memoID: memoID)
        if followers[memoID]?.id == id { followers[memoID] = nil }
      }
      followers[memoID] = (id, task)
    }

    func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async {
      guard let activity = activities.removeValue(forKey: memoID) ?? platformActivity(of: memoID) else { return }
      followers.removeValue(forKey: memoID)?.task.cancel()
      tokens.finish(memoID)
      let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
      let policy: ActivityUIDismissalPolicy =
        switch dismissal {
        case .immediate: .immediate
        case .later: .after(Date().addingTimeInterval(15 * 60))
        }
      await activity.end(content, dismissalPolicy: policy)
    }

    func endStaleActivities() async {
      if let running = sweeping { return await running.value }
      let task = Task { [sweeper] in
        for memoID in await sweeper.sweep() { follow(memoID) }
      }
      sweeping = task
      await task.value
      sweeping = nil
    }

    func handedOverActivities() -> [HandedOverActivity] {
      Activity<MemoAttributes>.activities.compactMap { activity in
        let live = activity.activityState == .active || activity.activityState == .stale
        guard live, !activity.content.state.phase.isClientPhase else { return nil }
        return HandedOverActivity(
          memoID: activity.attributes.memoId, phase: activity.content.state.phase,
          startedAt: activity.attributes.startedAt, remoteUpdates: activity.pushToken != nil,
          serverKey: activity.attributes.serverKey)
      }
    }

    /// An activity of an earlier run (or one already handed over) is only known to the system.
    private func platformActivity(of memoID: String) -> Activity<MemoAttributes>? {
      Activity<MemoAttributes>.activities.first { $0.attributes.memoId == memoID }
    }

    func endClientPhaseActivities(except memoIDs: Set<String>) async {
      for orphan in Activity<MemoAttributes>.activities
      where orphan.content.state.phase.isClientPhase && !memoIDs.contains(orphan.attributes.memoId)
        && activities[orphan.attributes.memoId] == nil
      {
        await orphan.end(nil, dismissalPolicy: .immediate)
        tokens.finish(orphan.attributes.memoId)
      }
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
  private(set) var staleSweeps = 0
  /// The memos each orphan sweep spared.
  private(set) var sparedBySweeps: [Set<String>] = []

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

  func endClientPhaseActivities(except memoIDs: Set<String>) {
    orphanSweeps += 1
    sparedBySweeps.append(memoIDs)
  }

  func endStaleActivities() { staleSweeps += 1 }

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
