import IrisCapture
import IrisCore
import Observation
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
  func registerCategories() {
    center.setNotificationCategories([
      UNNotificationCategory(identifier: "MEMO_DONE", actions: [], intentIdentifiers: [], options: [])
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

/// The ask a tapped factory notification is about, handed from the notification delegate to `RootView`. A tap that launches the
/// app lands here before any view exists, so it waits until the root consumes it.
@MainActor
@Observable
final class FactoryTapRouter {
  static let shared = FactoryTapRouter()

  private(set) var pendingAskID: String?

  func tapped(askID: String) { pendingAskID = askID }

  func consume() { pendingAskID = nil }
}

/// Forwards the APNs callbacks, which only an app delegate receives, to ``PushRegistrar/shared``. It is also the notification
/// center's delegate: a factory alert shows as a banner in the foreground and opens Decisions on tap; any other notification
/// keeps the system default (not shown while the app is open, nothing on tap).
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  @MainActor
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    FactoryPush.askID(userInfo: notification.request.content.userInfo) == nil ? [] : [.banner, .sound]
  }

  @MainActor
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let askID = FactoryPush.askID(userInfo: response.notification.request.content.userInfo) else { return }
    FactoryTapRouter.shared.tapped(askID: askID)
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { await PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    PushRegistrar.shared.didFail(error)
  }
}
