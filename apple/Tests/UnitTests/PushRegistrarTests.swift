import Foundation
import IrisCore
import IrisTelemetry
import Testing
import UserNotifications

@testable import Iris

private final class FakePushSystem: PushSystem {
  var status: UNAuthorizationStatus = .notDetermined
  var grants = true
  private(set) var authorizationRequests = 0
  private(set) var categoryRegistrations = 0
  private(set) var registrations = 0
  private(set) var order: [String] = []

  func authorizationStatus() async -> UNAuthorizationStatus { status }
  func requestAuthorization() async -> Bool {
    order.append("authorize")
    authorizationRequests += 1
    status = grants ? .authorized : .denied
    return grants
  }
  func registerCategories() { categoryRegistrations += 1 }
  func registerForRemoteNotifications() {
    order.append("register")
    registrations += 1
  }
}

private final class EventLog {
  private(set) var events: [(name: String, severity: LogSeverity, attributes: [String: AttributeValue])] = []
  func record(_ name: String, _ severity: LogSeverity, _ attributes: [String: AttributeValue]) {
    events.append((name, severity, attributes))
  }
  var names: [String] { events.map(\.name) }
}

private final class ServerChoice {
  var key: String? = "server-a"
}

@MainActor
private final class Rig {
  let system = FakePushSystem()
  let client = FakeAPIClient()
  let log = EventLog()
  private let choice = ServerChoice()
  let registrar: PushRegistrar

  /// The saved connection's server key; nil is "no connection saved".
  var serverKey: String? {
    get { choice.key }
    set { choice.key = newValue }
  }

  init(environment: APNsEnvironment = .sandbox) {
    let client = client
    let log = log
    let choice = choice
    registrar = PushRegistrar(
      system: system, environment: environment,
      target: { choice.key.map { PushTarget(serverKey: $0, client: client) } },
      log: { log.record($0, $1, $2) })
  }

  func registerCalls() async -> [RegisterDeviceRequest] {
    await client.calls.compactMap {
      if case .registerDevice(let request) = $0 { return request }
      return nil
    }
  }
}

@MainActor
@Suite("Push registration")
struct PushRegistrarTests {
  @Test("the token is sent as lowercase hex with the sandbox environment")
  func sendsHexToken() async {
    let rig = Rig()
    await rig.registrar.didRegister(deviceToken: Data([0x00, 0xAB, 0x0F, 0xFF]))
    let calls = await rig.registerCalls()
    #expect(calls.count == 1)
    #expect(calls.first?.apnsToken == .set("00ab0fff"))
    #expect(calls.first?.apnsEnv == .set(.sandbox))
    #expect(calls.first?.platform == .ios)
  }

  @Test("a production build reports the production environment")
  func productionEnvironment() async {
    let rig = Rig(environment: .production)
    await rig.registrar.didRegister(deviceToken: Data([1, 2]))
    #expect(await rig.registerCalls().first?.apnsEnv == .set(.production))
  }

  @Test("the same token and server are sent once")
  func dedupes() async {
    let rig = Rig()
    await rig.registrar.didRegister(deviceToken: Data([1, 2, 3]))
    await rig.registrar.didRegister(deviceToken: Data([1, 2, 3]))
    await rig.registrar.foregrounded()
    #expect(await rig.registerCalls().count == 1)
  }

  @Test("a changed token is sent again")
  func tokenChange() async {
    let rig = Rig()
    await rig.registrar.didRegister(deviceToken: Data([1]))
    await rig.registrar.didRegister(deviceToken: Data([2]))
    #expect(await rig.registerCalls().map(\.apnsToken) == [.set("01"), .set("02")])
  }

  @Test("a changed connection sends the held token to the new server")
  func connectionChange() async {
    let rig = Rig()
    await rig.registrar.didRegister(deviceToken: Data([7]))
    rig.serverKey = "server-b"
    await rig.registrar.connectionChanged()
    #expect(await rig.registerCalls().count == 2)
  }

  @Test("a failed send is retried on the next foreground")
  func retriesAfterFailure() async {
    let rig = Rig()
    await rig.client.enqueueFailure(.transport(.notConnectedToInternet), for: .registerDevice)
    await rig.registrar.didRegister(deviceToken: Data([9]))
    #expect(rig.log.names.contains("push.register_send_failed"))
    await rig.registrar.foregrounded()
    #expect(await rig.registerCalls().count == 2)
    #expect(rig.log.names.last == "push.registered")
  }

  @Test("with no saved connection nothing is asked, registered or sent")
  func noConnection() async {
    let rig = Rig()
    rig.serverKey = nil
    await rig.registrar.connectionChanged()
    await rig.registrar.didRegister(deviceToken: Data([1]))
    #expect(rig.system.authorizationRequests == 0 && rig.system.registrations == 0)
    #expect(await rig.registerCalls().isEmpty)
  }

  @Test("permission is asked once; categories and APNs registration repeat with every connection change")
  func authorizationOnce() async {
    let rig = Rig()
    await rig.registrar.connectionChanged()
    await rig.registrar.connectionChanged()
    #expect(rig.system.authorizationRequests == 1)
    #expect(rig.system.categoryRegistrations == 2)
    #expect(rig.system.registrations == 2)
  }

  @Test("APNs registration starts before the permission prompt, which waits for a tap")
  func registersBeforePrompt() async {
    let rig = Rig()
    await rig.registrar.connectionChanged()
    #expect(rig.system.order == ["register", "authorize"])
  }

  @Test("a denied permission still registers: the token is useful for Live Activities")
  func denied() async {
    let rig = Rig()
    rig.system.status = .denied
    await rig.registrar.connectionChanged()
    #expect(rig.system.authorizationRequests == 0 && rig.system.registrations == 1)
  }

  @Test("a registration failure (the simulator has no APNs) is logged at info and sends nothing")
  func registrationFailure() async {
    let rig = Rig()
    rig.registrar.didFail(NSError(domain: NSCocoaErrorDomain, code: 3010))
    #expect(rig.log.events.map(\.severity) == [.info])
    #expect(await rig.registerCalls().isEmpty)
  }

  @Test("no event carries the token")
  func tokenStaysOutOfLogs() async {
    let rig = Rig()
    await rig.registrar.didRegister(deviceToken: Data([0xDE, 0xAD, 0xBE, 0xEF]))
    for event in rig.log.events {
      for value in event.attributes.values {
        if case .string(let text) = value { #expect(!text.contains("deadbeef")) }
      }
    }
  }
}
