import Foundation
import IrisCore
import UserNotifications
import os

/// What one memo says in Notification Center.
nonisolated struct MemoNotification: Equatable, Sendable {
  let memoID: String
  /// The connection the memo belongs to (``MemoNotifier/connectionID``): a click after a server switch is ignored.
  let connectionID: String
  let title: String
  let body: String
}

/// Whether the user lets Iris post notifications, as System Settings has it right now.
nonisolated enum NotificationPermission: Equatable, Sendable {
  /// Never asked: the system prompt has not been answered.
  case undetermined
  case denied
  case allowed
}

/// The system notification centre behind ``MemoNotifier``: a port, so the notifier is tested without asking the user for
/// permission or posting to the real one.
nonisolated protocol NotificationPoster: Sendable {
  /// The permission as it is now. Never cached by the notifier: the user can enable notifications in System Settings at any time.
  func permission() async -> NotificationPermission
  /// Shows the system prompt (once; it stays up until the user answers) and returns whether notifications may be shown.
  func requestAuthorization() async -> Bool
  func post(_ notification: MemoNotification) async throws
  /// Takes this banner back (shown or still pending): it was posted for a connection that is gone.
  func withdraw(_ notification: MemoNotification) async
  /// Takes back every banner of a connection other than `connectionID`: a server switch, or a banner left from an earlier run.
  func withdrawAll(exceptConnection connectionID: String) async
}

/// The kinds of banner a memo earns, by the state it is in. A memo is announced on the **transition** into one of them.
nonisolated enum Announcement: Equatable, Sendable {
  /// `notified`: finished.
  case done
  /// `needs_route`: parked, waiting for the user to pick a destination.
  case needsRoute
  /// `failed`: stopped on a step.
  case failed

  init?(state: MemoState) {
    switch state {
    case .notified: self = .done
    case .needsRoute: self = .needsRoute
    case .failed: self = .failed
    case .receiving, .received, .transcribed, .routed, .acted, .summarized: return nil
    }
  }
}

/// What the notifier tells the device log: counts and kinds, never a word of a banner or a memo.
nonisolated enum NotifierEvent: Equatable, Sendable {
  case posted(memoID: String, kind: Announcement)
  /// A banner taken back because the connection moved while the system took it.
  case withdrawn(memoID: String, kind: Announcement)
  /// A catch-up announced `announced` memos of the `seen` it looked at.
  case caughtUp(announced: Int, seen: Int)
}

/// Local notifications for memos that finished, parked or failed while the app runs (TDD §5). Three feeds, one rule:
///
/// - the event stream (`memo.updated` carries the state; `memo.done` only the id),
/// - the catch-up after the stream (re)connects: an unfiltered fetch of the newest memos, so one that finished while the stream
///   was down (it has no replay) is announced once, the first fetch of a connection being only the baseline,
/// - nothing else: APNs for an app that is asleep comes later.
///
/// **Transition-based:** ``announced`` holds the kind each memo was last announced as. A memo announces when it is in a kind it was
/// not announced as; it leaves the record when it runs again (a retry, a route answer), so the next finish is a new transition.
/// A repeated event, a second feed for the same memo, or a catch-up that sees what an event already said, posts nothing.
///
/// Before posting, an event's memo is fetched and must be in an announceable state, so a stale copy never announces a running
/// memo. A fetch or post that keeps failing is tried three times, logged, and forgotten: the next event may try again.
@MainActor
final class MemoNotifier {
  /// At most this many memos are announced by one catch-up (newest first); the rest are recorded as seen. A long outage does
  /// not become a wall of banners.
  static let catchUpLimit = 5

  private let poster: any NotificationPoster
  /// The memo behind a `memo.done` id, fetched fresh from the server; nil when it cannot be had now. Set by the composition
  /// root once it can name itself.
  var lookup: (String) async -> Memo?
  /// The newest memos of the server, **unfiltered** (History's filters must not hide a finished memo from the catch-up); nil
  /// when they cannot be had now. Set by the composition root.
  var fetchRecent: () async -> [Memo]? = { nil }
  /// Where the device log hears of banners (see ``NotifierEvent``).
  var report: (NotifierEvent) -> Void = { _ in }
  private let retryDelays: [Duration]
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "notifier")
  /// The kind each memo was announced as (or recorded as already finished by the baseline).
  private var announced: [String: Announcement] = [:]
  /// Memos whose state this connection has seen, by id.
  private var seen: Set<String> = []
  private var inFlight: Set<String> = []
  /// Memos asked for again while one delivery was running: it looks again, fresh, when it is through.
  private var again: Set<String> = []
  /// The newest `startedAt` of the baseline; `nil` before the baseline, ``Date/distantPast`` for an empty one. A memo this
  /// connection never saw is new only when it started after it.
  private var baselineNewest: Date?
  /// The prompt in flight. Single-flight: every memo that finishes while it is up waits on it, none starts a second one.
  private var requesting: Task<Bool, Never>?

  /// - Parameters:
  ///   - lookup: The memo behind a `memo.done` id: the list's copy, else a fetch; nil when it cannot be had now.
  ///   - retryDelays: The waits between the tries of one call after a failed lookup or post: three tries in all by default.
  init(
    poster: any NotificationPoster, connectionID: String, lookup: @escaping (String) async -> Memo?,
    retryDelays: [Duration] = [.seconds(1), .seconds(5)]
  ) {
    self.poster = poster
    self.connectionID = connectionID
    self.lookup = lookup
    self.retryDelays = retryDelays
  }

  /// Shows the system prompt when the permission was never asked, without waiting for it: History and the event stream must not
  /// depend on an answer.
  func requestPermissionIfNeeded() {
    Task { _ = await isAllowed() }
  }

  /// Which connection the notifier works for; bumped by ``reset(connectionID:)``. A caller reads it when the event arrives and hands it to
  /// ``memoDone(id:generation:)``, so a task of the old server that only starts after the switch is dropped.
  private(set) var generation = 0

  /// Names the saved connection the banners belong to (see ``MacCompositionRoot/connectionID(for:)``): it survives a restart, so a
  /// banner from before one still opens its memo, and changes only with the server URL or token.
  private(set) var connectionID: String

  /// The first catch-up of this connection has recorded what was already finished.
  var hasBaseline: Bool { baselineNewest != nil }

  /// Forgets what was announced: the connection moved to another server, whose memos are not these. Banners of the old server
  /// that are still in Notification Center are taken back.
  func reset(connectionID: String) {
    generation += 1
    self.connectionID = connectionID
    announced = [:]
    seen = []
    inFlight = []
    again = []
    baselineNewest = nil
    withdrawForeignBanners()
  }

  /// Takes back the banners of any other connection (left from an earlier run or an earlier server). Run at launch and by
  /// ``reset(connectionID:)``.
  func withdrawForeignBanners() {
    let poster = poster
    let mine = connectionID
    // Fire and forget: the system call is quick and has nothing to report; a banner that stays is only noise.
    Task { await poster.withdrawAll(exceptConnection: mine) }
  }

  /// Records what an event says about a memo's state. `true` when the memo is now in a kind it was not announced as: the caller
  /// delivers it (``memoDone(id:generation:)``). A state that is not announceable clears the record, so the memo's next
  /// finish (after a retry or a route answer) is a new transition.
  func noteState(of event: MemoEvent, generation expected: Int? = nil) -> Bool {
    guard (expected ?? generation) == generation else { return false }
    seen.insert(event.id)
    guard let kind = Announcement(state: event.state) else {
      announced[event.id] = nil
      return false
    }
    return announced[event.id] != kind
  }

  /// Announces `id` once per transition. `expected` is the ``generation`` the event was seen under (the current one when nil);
  /// every await re-checks it, so nothing of another server is looked up, posted or recorded on this one.
  func memoDone(id: String, generation expected: Int? = nil) async {
    await deliver(id: id, generation: expected ?? generation, known: nil)
  }

  /// The catch-up after the event stream (re)connected. The first call of a connection is the baseline: what is finished
  /// already is recorded, nothing is announced. Later calls announce the memos that reached a kind since: ones the connection
  /// had seen running, and ones it never saw that started after the baseline's newest.
  func catchUp(generation expected: Int? = nil) async {
    let mine = expected ?? generation
    let fetched = await fetchRecent()
    guard mine == generation, let page = fetched else { return }
    guard let baseline = baselineNewest else {
      baselineNewest = page.map(\.startedAt).max() ?? .distantPast
      for memo in page {
        // A memo an event already told us about is not the baseline's to record: its own delivery decides.
        guard seen.insert(memo.id).inserted else { continue }
        if let kind = Announcement(state: memo.state), !memo.isDeleted { announced[memo.id] = kind }
      }
      return
    }
    var due: [Memo] = []
    for memo in page where !memo.isDeleted {
      let wasSeen = seen.contains(memo.id)
      seen.insert(memo.id)
      guard let kind = Announcement(state: memo.state) else {
        announced[memo.id] = nil
        continue
      }
      guard announced[memo.id] != kind, wasSeen || memo.startedAt > baseline else {
        // Older than the baseline and never seen, or already announced: recorded, not announced.
        if !wasSeen { announced[memo.id] = kind }
        continue
      }
      due.append(memo)
    }
    // Newest first, bounded; the rest are recorded so the next catch-up does not bring them back.
    due.sort { $0.startedAt > $1.startedAt }
    for memo in due.dropFirst(Self.catchUpLimit) { announced[memo.id] = Announcement(state: memo.state) }
    for memo in due.prefix(Self.catchUpLimit) {
      guard mine == generation else { return }
      await deliver(id: memo.id, generation: mine, known: memo)
    }
    if mine == generation { report(.caughtUp(announced: min(due.count, Self.catchUpLimit), seen: page.count)) }
  }

  /// `known` is a copy the server has just sent (the catch-up page): used for the first try instead of a fetch.
  private func deliver(id: String, generation mine: Int, known: Memo?) async {
    guard mine == generation else { return }
    guard inFlight.insert(id).inserted else {
      // One delivery is running for this memo; it may have read the state before this call's news. It looks again when done.
      again.insert(id)
      return
    }
    var first = known
    repeat {
      again.remove(id)
      let outcome = await attempt(id: id, generation: mine, known: first)
      first = nil
      guard mine == generation else { return }
      if outcome == .gaveUp { break }
    } while again.contains(id)
    again.remove(id)
    inFlight.remove(id)
  }

  private enum Outcome { case settled, gaveUp }

  private func attempt(id: String, generation mine: Int, known: Memo?) async -> Outcome {
    var prefetched = known
    for delay in [nil] + retryDelays.map({ Optional($0) }) {
      if let delay {
        guard (try? await Task.sleep(for: delay)) != nil, mine == generation else { return .settled }
      }
      // Asked again for every memo: a denial from before the user enabled notifications must not stick.
      guard await isAllowed(), mine == generation else { return .settled }
      let found: Memo?
      if let copy = prefetched {
        found = copy
        prefetched = nil
      } else {
        found = await lookup(id)
      }
      guard mine == generation else { return .settled }
      guard let memo = found else { continue }
      guard !memo.isDeleted else {
        announced[id] = Announcement(state: memo.state) ?? .done
        return .settled
      }
      // A memo the server does not call announceable yet is not announced, and not remembered either: its next event is still to come.
      guard let kind = Announcement(state: memo.state) else {
        announced[id] = nil
        return .settled
      }
      guard announced[id] != kind else { return .settled }
      let notification = Self.notification(for: memo, connectionID: connectionID)
      do {
        try await poster.post(notification)
      } catch {
        guard mine == generation else { return .settled }
        continue
      }
      guard mine == generation else {
        // The connection moved while the system took the banner: it names the old server's memo, so it is taken back.
        await poster.withdraw(notification)
        report(.withdrawn(memoID: id, kind: kind))
        return .settled
      }
      seen.insert(id)
      announced[id] = kind
      report(.posted(memoID: id, kind: kind))
      return .settled
    }
    // Every try failed: nothing is recorded, so a later event for the memo may try again.
    logger.error("notification for a memo not delivered after \(self.retryDelays.count + 1) tries")
    return .gaveUp
  }

  private func isAllowed() async -> Bool {
    switch await poster.permission() {
    case .allowed: return true
    case .denied: return false
    case .undetermined:
      if let requesting { return await requesting.value }
      let request = Task { await poster.requestAuthorization() }
      requesting = request
      let granted = await request.value
      requesting = nil
      return granted
    }
  }

  /// What a banner says. Never the transcript, the reply or the park reason (a reason can hold a spoken tab name; the alert
  /// contract, AGENTS.md): a finished memo shows its route and the summary's headline, a parked or failed one generic words.
  /// `rowHeadline` is not used: without a summary it is the transcript.
  static func notification(for memo: Memo, connectionID: String) -> MemoNotification {
    let title: String
    let body: String
    switch memo.state {
    case .needsRoute:
      title = String(localized: "Where should this go?", comment: "Notification title: a parked memo")
      body = String(localized: "Open Iris to choose a route.", comment: "Notification body: a parked memo")
    case .failed:
      title = String(localized: "Memo failed", comment: "Notification title: a failed memo")
      body = String(localized: "Open Iris to retry it.", comment: "Notification body: a failed memo")
    default:
      title = memo.routeLabel
      body = memo.summary?.headline ?? String(localized: "Done.", comment: "Notification body: no summary")
    }
    return MemoNotification(memoID: memo.id, connectionID: connectionID, title: title, body: body)
  }
}

/// `UNUserNotificationCenter`. The memo id travels in `userInfo`, so a click on the banner can open that memo.
nonisolated struct UserNotificationPoster: NotificationPoster {
  static let memoIDKey = "memoID"
  static let connectionKey = "connectionID"
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "notifications")

  func permission() async -> NotificationPermission {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .notDetermined: .undetermined
    case .denied: .denied
    case .authorized, .provisional, .ephemeral: .allowed
    @unknown default: .denied
    }
  }

  func requestAuthorization() async -> Bool {
    do {
      return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    } catch {
      logger.error("notification permission failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  func post(_ notification: MemoNotification) async throws {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    content.userInfo = [Self.memoIDKey: notification.memoID, Self.connectionKey: notification.connectionID]
    // The memo id is the request id: a second post for the same memo replaces the first instead of stacking.
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: notification.memoID, content: content, trigger: nil))
  }

  func withdraw(_ notification: MemoNotification) async {
    let center = UNUserNotificationCenter.current()
    // Only the banner of that connection: the same memo id on a newer connection is somebody else's.
    let delivered = await center.deliveredNotifications().filter {
      $0.request.identifier == notification.memoID
        && $0.request.content.userInfo[Self.connectionKey] as? String == notification.connectionID
    }
    center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
    center.removePendingNotificationRequests(withIdentifiers: [notification.memoID])
  }

  func withdrawAll(exceptConnection connectionID: String) async {
    let center = UNUserNotificationCenter.current()
    let foreign = await center.deliveredNotifications().filter {
      $0.request.content.userInfo[Self.connectionKey] as? String != connectionID
    }
    center.removeDeliveredNotifications(withIdentifiers: foreign.map(\.request.identifier))
    let pending = await center.pendingNotificationRequests().filter {
      $0.content.userInfo[Self.connectionKey] as? String != connectionID
    }
    center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
  }
}

/// Shows a banner even while the app is "active" (a menu-bar app often is, with its popover open) and opens the memo a
/// clicked banner is about.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
  private let open: @MainActor @Sendable (_ memoID: String, _ connectionID: String) -> Void

  init(open: @escaping @MainActor @Sendable (_ memoID: String, _ connectionID: String) -> Void) {
    self.open = open
  }

  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard let id = info[UserNotificationPoster.memoIDKey] as? String,
      let connection = info[UserNotificationPoster.connectionKey] as? String
    else { return }
    await open(id, connection)
  }
}

/// Posts nothing and remembers what it was asked to: the fake composition's poster (no permission prompt in a screenshot
/// run) and the tests'. A test sets the permission, holds the prompt, holds a post, or makes the next posts fail.
actor RecordingNotificationPoster: NotificationPoster {
  struct PostFailure: Error {}

  /// Every post the system accepted, in order, withdrawn or not.
  private(set) var posted: [MemoNotification] = []
  /// What Notification Center would still show: a post a withdraw has not taken back.
  private(set) var delivered: [MemoNotification] = []
  private(set) var requests = 0
  private var current: NotificationPermission
  private var holdsPrompt: Bool
  private var holdsPosts = false
  private var failures = 0
  private var prompt: CheckedContinuation<Bool, Never>?
  private var held: CheckedContinuation<Void, Never>?
  private(set) var postsStarted = 0

  /// - Parameters:
  ///   - permission: What System Settings says; `.undetermined` until the prompt is answered.
  ///   - holdsPrompt: The prompt stays unanswered until ``answerPrompt(_:)``.
  init(permission: NotificationPermission = .allowed, holdsPrompt: Bool = false) {
    current = permission
    self.holdsPrompt = holdsPrompt
  }

  func permission() -> NotificationPermission { current }

  func requestAuthorization() async -> Bool {
    requests += 1
    if holdsPrompt {
      let granted = await withCheckedContinuation { prompt = $0 }
      current = granted ? .allowed : .denied
      return granted
    }
    current = current == .undetermined ? .allowed : current
    return current == .allowed
  }

  func post(_ notification: MemoNotification) async throws {
    postsStarted += 1
    if holdsPosts { await withCheckedContinuation { held = $0 } }
    if failures > 0 {
      failures -= 1
      throw PostFailure()
    }
    posted.append(notification)
    delivered.append(notification)
  }

  func withdraw(_ notification: MemoNotification) {
    delivered.removeAll { $0 == notification }
  }

  func withdrawAll(exceptConnection connectionID: String) {
    delivered.removeAll { $0.connectionID != connectionID }
  }

  /// The user answered the held prompt.
  func answerPrompt(_ granted: Bool) {
    prompt?.resume(returning: granted)
    prompt = nil
  }

  /// The user changed the permission in System Settings.
  func setPermission(_ permission: NotificationPermission) { current = permission }

  /// The next `count` posts throw.
  func failNextPosts(_ count: Int) { failures = count }

  /// Posts wait (the system is slow to take the banner) until ``releasePost()``.
  func holdPosts(_ hold: Bool) { holdsPosts = hold }

  /// The held post goes through.
  func releasePost() {
    held?.resume()
    held = nil
  }
}
