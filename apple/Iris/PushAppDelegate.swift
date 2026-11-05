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

/// Forwards the APNs callbacks, which only an app delegate receives, to ``PushRegistrar/shared``.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { await PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    PushRegistrar.shared.didFail(error)
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    Task { await PushRegistrar.shared.foregrounded() }
  }
}
