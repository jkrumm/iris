import Foundation
import IrisCore
import IrisTelemetry
import UserNotifications

/// The slice of the OS the registrar drives; a fake stands in for it in the unit tests.
protocol PushSystem: AnyObject {
  func authorizationStatus() async -> UNAuthorizationStatus
  /// Asks for alert, sound and badge; false when the user declined or the request failed.
  func requestAuthorization() async -> Bool
  func registerCategories()
  func registerForRemoteNotifications()
}

/// The server a registration goes to: the key tells servers apart (``ConnectionCredentials/serverKey``), the client carries the
/// device token for it.
struct PushTarget {
  let serverKey: String
  let client: any APIClient
}

/// Gets this device's APNs token onto the server: asks for notification permission once a connection is saved, registers with
/// APNs, and sends the hex token with the environment through `POST /devices/register`. It sends again only when the token,
/// the environment or the server changes, and retries a failed send on the next foreground or connection change.
///
/// The token never reaches a log: events carry its length, the environment and the outcome.
final class PushRegistrar {
  private let system: any PushSystem
  private let target: () -> PushTarget?
  private let environment: APNsEnvironment
  private let deviceName: String
  private let log: (String, LogSeverity, [String: AttributeValue]) -> Void

  private var token: String?
  /// What the server last confirmed: server, environment and token together.
  private var sent: String?
  private var sending = false

  init(
    system: any PushSystem, environment: APNsEnvironment, deviceName: String = "iPhone",
    target: @escaping () -> PushTarget?,
    log: @escaping (String, LogSeverity, [String: AttributeValue]) -> Void = { name, severity, attributes in
      DeviceLog.shared.event(name, severity: severity, attributes)
    }
  ) {
    self.system = system
    self.environment = environment
    self.deviceName = deviceName
    self.target = target
    self.log = log
  }

  /// A connection exists or changed (also at launch): categories, the APNs registration, then the one-time permission prompt.
  /// Without a saved connection nothing happens, so the prompt never fires on a first launch before the server is set up.
  func connectionChanged() async {
    guard target() != nil else { return }
    system.registerCategories()
    // The token does not depend on the permission, and the prompt waits for a tap: register first, ask second.
    system.registerForRemoteNotifications()
    if await system.authorizationStatus() == .notDetermined {
      let granted = await system.requestAuthorization()
      log("push.authorization", .info, ["granted": .bool(granted)])
    }
    await sendIfNeeded()
  }

  /// The app came to the foreground: a send that failed earlier gets another try.
  func foregrounded() async {
    await sendIfNeeded()
  }

  func didRegister(deviceToken: Data) async {
    token = Self.hex(deviceToken)
    log("push.token", .info, ["env": .string(environment.rawValue), "length": .int(deviceToken.count)])
    await sendIfNeeded()
  }

  /// The simulator always lands here (no APNs): recorded at info level, nothing surfaces to the user.
  func didFail(_ error: any Error) {
    let nsError = error as NSError
    log(
      "push.register_failed", .info,
      ["error.domain": .string(nsError.domain), "error.code": .int(nsError.code)])
  }

  static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  /// One request at a time: a token that changes while a request is out is sent after its answer, never beside it.
  private func sendIfNeeded() async {
    guard !sending else { return }
    sending = true
    defer { sending = false }
    while let token, let target = target() {
      let key = "\(target.serverKey)|\(environment.rawValue)|\(token)"
      guard key != sent else { return }
      let request = RegisterDeviceRequest(
        name: deviceName, platform: .ios, apnsToken: .set(token), apnsEnv: .set(environment))
      do {
        let response = try await target.client.registerDevice(request)
        sent = key
        log(
          "push.registered", .info,
          ["env": .string(environment.rawValue), "has_apns_token": .bool(response.hasApnsToken)])
      } catch {
        log("push.register_send_failed", .warn, ["error": .string(String(describing: type(of: error)))])
        return
      }
    }
  }
}
