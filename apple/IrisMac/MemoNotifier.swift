import Foundation
import IrisCore
import UserNotifications
import os

/// What one finished memo says in Notification Center.
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
}

/// One local notification per finished memo while the app runs (TDD §5), fed by History's live `memo.done` events. A memo that
/// finished while the stream was down is not announced (known limit); APNs for an app that is asleep comes later.
///
/// A memo is announced once: ``posted`` holds the ones the system accepted, ``inFlight`` the ones being fetched or posted right
/// now. Before posting, the memo is fetched and must be result-ready, so a stale copy never announces a running memo. A
/// fetch or post that keeps failing is tried three times, logged, and then forgotten: the next event for the memo may try again.
@MainActor
final class MemoNotifier {
  private let poster: any NotificationPoster
  /// The memo behind a `memo.done` id, fetched fresh from the server; nil when it cannot be had now. Set by the composition
  /// root once it can name itself.
  var lookup: (String) async -> Memo?
  private let retryDelays: [Duration]
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "notifier")
  private var posted: Set<String> = []
  private var inFlight: Set<String> = []
  /// The prompt in flight. Single-flight: every memo that finishes while it is up waits on it, none starts a second one.
  private var requesting: Task<Bool, Never>?

  /// - Parameters:
  ///   - lookup: The memo behind a `memo.done` id: the list's copy, else a fetch; nil when it cannot be had now.
  ///   - retryDelays: The waits between the tries of one call after a failed lookup or post: three tries in all by default.
  init(
    poster: any NotificationPoster, lookup: @escaping (String) async -> Memo?,
    retryDelays: [Duration] = [.seconds(1), .seconds(5)]
  ) {
    self.poster = poster
    self.lookup = lookup
    self.retryDelays = retryDelays
  }

  /// Shows the system prompt when the permission was never asked, without waiting for it: History and the event stream must not
  /// depend on an answer.
  func requestPermissionIfNeeded() {
    Task { _ = await isAllowed() }
  }

  /// Which connection the notifier works for; bumped by ``reset()``. A caller reads it when the event arrives and hands it to
  /// ``memoDone(id:generation:)``, so a task of the old server that only starts after the switch is dropped.
  private(set) var generation = 0

  /// Names the connection the banners belong to; a click on one of another connection is ignored.
  private(set) var connectionID = UUID().uuidString

  /// Forgets what was announced: the connection moved to another server, whose memos are not these.
  func reset() {
    generation += 1
    connectionID = UUID().uuidString
    posted = []
    inFlight = []
  }

  /// Announces `id` once. `expected` is the ``generation`` the event was seen under (the current one when nil); every await
  /// re-checks it, so nothing of another server is looked up, posted or recorded on this one.
  func memoDone(id: String, generation expected: Int? = nil) async {
    let mine = expected ?? generation
    guard mine == generation, !posted.contains(id), inFlight.insert(id).inserted else { return }
    defer { if mine == generation { inFlight.remove(id) } }
    for delay in [nil] + retryDelays.map({ Optional($0) }) {
      if let delay {
        guard (try? await Task.sleep(for: delay)) != nil, mine == generation else { return }
      }
      // Asked again for every memo: a denial from before the user enabled notifications must not stick.
      guard await isAllowed(), mine == generation else { return }
      let found = await lookup(id)
      guard mine == generation else { return }
      guard let memo = found else { continue }
      guard !memo.isDeleted else {
        posted.insert(id)
        return
      }
      // A memo the server does not call done yet is not announced, and not remembered either: its `memo.done` is still to come.
      guard memo.state.isResultReady else { return }
      do {
        try await poster.post(Self.notification(for: memo, connectionID: connectionID))
      } catch {
        guard mine == generation else { return }
        continue
      }
      guard mine == generation else { return }
      posted.insert(id)
      return
    }
    // Every try failed: nothing is recorded, so a later event for the memo may try again.
    logger.error("notification for a memo not delivered after \(self.retryDelays.count + 1) tries")
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
/// run) and the tests'. A test sets the permission, holds the prompt, or makes the next posts fail.
actor RecordingNotificationPoster: NotificationPoster {
  struct PostFailure: Error {}

  private(set) var posted: [MemoNotification] = []
  private(set) var requests = 0
  private var current: NotificationPermission
  private var holdsPrompt: Bool
  private var failures = 0
  private var prompt: CheckedContinuation<Bool, Never>?

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

  func post(_ notification: MemoNotification) throws {
    if failures > 0 {
      failures -= 1
      throw PostFailure()
    }
    posted.append(notification)
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
}
