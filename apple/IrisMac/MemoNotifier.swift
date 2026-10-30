import Foundation
import IrisCore
import UserNotifications
import os

/// What one finished memo says in Notification Center.
nonisolated struct MemoNotification: Equatable, Sendable {
  let memoID: String
  let title: String
  let body: String
}

/// The system notification centre behind ``MemoNotifier``: a port, so the notifier is tested without asking the user for
/// permission or posting to the real one.
nonisolated protocol NotificationPoster: Sendable {
  /// Asks for permission (the system shows its prompt once); true when notifications may be shown.
  func requestAuthorization() async -> Bool
  func post(_ notification: MemoNotification) async
}

/// One local notification per finished memo while the app runs (TDD §5). Fed by History's `memo.done` events; APNs for an
/// app that is asleep comes later.
@MainActor
final class MemoNotifier {
  private let poster: any NotificationPoster
  private let lookup: (String) async -> Memo?
  /// Memos already announced (or being announced): a replayed event, or one the list and the stream both deliver, posts once.
  private var announced: Set<String> = []
  private var isAuthorized: Bool?

  /// - Parameter lookup: The memo behind a `memo.done` id: the list's copy, else a fetch.
  init(poster: any NotificationPoster, lookup: @escaping (String) async -> Memo?) {
    self.poster = poster
    self.lookup = lookup
  }

  /// Asks for permission once, when the connection starts, so the system prompt does not appear mid-result.
  func prepare() async {
    guard isAuthorized == nil else { return }
    isAuthorized = await poster.requestAuthorization()
  }

  func memoDone(id: String) async {
    guard announced.insert(id).inserted else { return }
    await prepare()
    guard isAuthorized == true, let memo = await lookup(id), !memo.isDeleted else { return }
    await poster.post(Self.notification(for: memo))
  }

  /// The route says where the memo went, the headline what it was about.
  static func notification(for memo: Memo) -> MemoNotification {
    MemoNotification(memoID: memo.id, title: memo.routeLabel, body: memo.rowHeadline)
  }
}

/// `UNUserNotificationCenter`. The memo id travels in `userInfo`, so a click on the banner can open that memo.
nonisolated struct UserNotificationPoster: NotificationPoster {
  static let memoIDKey = "memoID"
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "notifications")

  func requestAuthorization() async -> Bool {
    do {
      return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    } catch {
      logger.error("notification permission failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  func post(_ notification: MemoNotification) async {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    content.userInfo = [Self.memoIDKey: notification.memoID]
    // The memo id is the request id: a second post for the same memo replaces the first instead of stacking.
    let request = UNNotificationRequest(identifier: notification.memoID, content: content, trigger: nil)
    do {
      try await UNUserNotificationCenter.current().add(request)
    } catch {
      logger.error("notification not posted: \(String(describing: error), privacy: .public)")
    }
  }
}

/// Shows a banner even while the app is "active" (a menu-bar app often is, with its popover open) and opens the memo a
/// clicked banner is about.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
  private let open: @MainActor @Sendable (String) -> Void

  init(open: @escaping @MainActor @Sendable (String) -> Void) {
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
    guard let id = response.notification.request.content.userInfo[UserNotificationPoster.memoIDKey] as? String else {
      return
    }
    await open(id)
  }
}

/// Posts nothing and remembers what it was asked to: the fake composition's poster (no permission prompt in a screenshot
/// run) and the tests'.
actor RecordingNotificationPoster: NotificationPoster {
  private(set) var posted: [MemoNotification] = []
  private let allowed: Bool

  init(allowed: Bool = true) {
    self.allowed = allowed
  }

  func requestAuthorization() -> Bool { allowed }

  func post(_ notification: MemoNotification) {
    posted.append(notification)
  }
}
