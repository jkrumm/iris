import IrisCapture
import IrisCore
import UIKit
import UserNotifications

/// The APNs environment this build's tokens belong to. Xcode development builds (Debug, installed from the mini) talk to the
/// sandbox host; a TestFlight or App Store build (Release) talks to production (Wave 22).
nonisolated enum PushEnvironment {
  static var current: APNsEnvironment {
    #if DEBUG
      .sandbox
    #else
      .production
    #endif
  }
}

/// UIKit and UserNotifications behind ``PushSystem``.
final class UIKitPushSystem: PushSystem {
  private var center: UNUserNotificationCenter { .current() }

  func authorizationStatus() async -> UNAuthorizationStatus {
    await center.notificationSettings().authorizationStatus
  }

  func requestAuthorization() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
  }

  /// `MEMO_DONE` is what the notification content extension (`IrisNotifications`) declares; the server sends it with the result alert.
  /// Its actions all start the app (a notification action cannot run an `AppIntent` on its own): Reply and Reply by voice open the
  /// conversation, Play speaks the reply (``NotificationRoute``).
  func registerCategories() {
    let actions = [
      UNNotificationAction(
        identifier: NotificationRoute.replyAction,
        title: String(localized: "Reply", comment: "Notification action: reply to the memo by typing"),
        options: [.foreground]),
      UNNotificationAction(
        identifier: NotificationRoute.replyByVoiceAction,
        title: String(localized: "Reply by voice", comment: "Notification action: reply to the memo by voice"),
        options: [.foreground]),
      UNNotificationAction(
        identifier: NotificationRoute.playAction,
        title: String(localized: "Play", comment: "Notification action: speak the memo's reply"),
        options: [.foreground]),
    ]
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: NotificationRoute.category, actions: actions, intentIdentifiers: [], options: [])
    ])
  }

  func registerForRemoteNotifications() {
    UIApplication.shared.registerForRemoteNotifications()
  }
}

extension PushRegistrar {
  /// The app's registrar. It reads the saved connection itself, so it needs nothing from the composition root; on fakes
  /// (`-IrisFakeCapture`: UI tests, `make run-sim`) there is no target and nothing is asked or sent.
  static let shared = PushRegistrar(
    system: UIKitPushSystem(), environment: PushEnvironment.current,
    target: {
      guard !FakeCapture.isRequested(), let credentials = KeychainCredentialStore().load() else { return nil }
      return PushTarget(
        serverKey: credentials.serverKey,
        client: URLSessionAPIClient(baseURL: credentials.serverURL, bearerToken: credentials.token))
    })
}

/// Forwards the APNs callbacks, which only an app delegate receives, to ``PushRegistrar/shared``, and is the notification
/// center's delegate: a tap or an action of a `MEMO_DONE` notification becomes a ``NotificationRoute``, and a notification
/// that arrives in the foreground is shown unless it belongs to the conversation on screen. The delegate is set before the
/// launch finishes, so a tap that cold-launches the app is delivered; the routes wait here until the root attaches.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  private var router: ConversationRouter?
  private var presence: ConversationPresence?
  private var play: ((String) async throws -> Void)?
  private var waiting: [NotificationRoute] = []

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  /// The composition root is up: routes that arrived before it are handled now. `play` speaks the reply of a memo.
  func attach(
    router: ConversationRouter, presence: ConversationPresence, play: @escaping (String) async throws -> Void
  ) {
    self.router = router
    self.presence = presence
    self.play = play
    let early = waiting
    waiting = []
    early.forEach(handle)
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { await PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    PushRegistrar.shared.didFail(error)
  }

  // MARK: UNUserNotificationCenterDelegate

  // Main actor on purpose: a nonisolated async delegate method ran the system's completion handler on a cooperative-pool
  // thread, which UIKit aborts on (Issue 211, the 17:32 crash in the device checklist).
  @MainActor
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let route = NotificationRoute.route(
      actionIdentifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
    guard let route else { return }
    handle(route)
  }

  @MainActor
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let onScreen = presence?.current
    return NotificationRoute.presentationOptions(
      for: notification.request.content.userInfo, onScreenThreadID: onScreen?.threadID,
      onScreenMemoIDs: onScreen?.memoIDs ?? [])
  }

  private func handle(_ route: NotificationRoute) {
    guard let router, let play else {
      waiting.append(route)
      return
    }
    switch route {
    case .open(let link):
      router.open(link)
    case .play(let memoID):
      Task {
        do {
          try await play(memoID)
        } catch {
          // Nothing to speak (or the player is busy): the conversation is the useful place to land.
          DeviceLog.shared.event("ui.route", ["memo": .string(memoID), "action": "play", "fallback": "open"])
          router.open(ConversationLink(memoID: memoID))
        }
      }
    }
  }
}
