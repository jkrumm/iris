import Foundation
import IrisCore
import Testing

@testable import IrisMac

@MainActor
@Suite("Connection tester")
struct ConnectionTesterTests {
  private static let url = "https://iris.example.com"

  private func make(_ fake: FakeAPIClient = FakeAPIClient()) -> (ConnectionTester, FakeAPIClient) {
    (ConnectionTester { _ in fake }, fake)
  }

  @Test("a healthy server with an accepted token is connected")
  func connected() async {
    let (tester, _) = make()
    tester.test(urlText: Self.url, tokenText: "t")
    #expect(tester.outcome == .testing)
    await tester.settled()
    #expect(tester.outcome == .connected)
  }

  @Test("a probe right after Save reads as saved")
  func savedConnected() async {
    let (tester, _) = make()
    tester.test(urlText: Self.url, tokenText: "t", saved: true)
    await tester.settled()
    #expect(tester.outcome == .savedConnected)
  }

  @Test("a 401 is a rejected token")
  func rejected() async {
    let (tester, fake) = make()
    await fake.enqueueFailure(.unauthorized, for: .whoami)
    tester.test(urlText: Self.url, tokenText: "t")
    await tester.settled()
    #expect(tester.outcome == .rejected)
  }

  @Test("a transport error and a gateway status are unreachable")
  func unreachable() async {
    for error in [APIError.transport(.notConnectedToInternet), .unexpectedStatus(502)] {
      let (tester, fake) = make()
      await fake.enqueueFailure(error, for: .health)
      tester.test(urlText: Self.url, tokenText: "t")
      await tester.settled()
      #expect(tester.outcome == .unreachable)
    }
  }

  @Test("a server answer that is not healthy is a server error")
  func serverError() async {
    for error in [APIError.unexpectedStatus(500), .decoding("bad")] {
      let (tester, fake) = make()
      await fake.enqueueFailure(error, for: .health)
      tester.test(urlText: Self.url, tokenText: "t")
      await tester.settled()
      #expect(tester.outcome == .serverError)
    }
  }

  @Test("unusable input is invalid and probes nothing")
  func invalid() async {
    let (tester, fake) = make()
    tester.test(urlText: "not a url", tokenText: "")
    #expect(tester.outcome == .invalid)
    #expect(await !fake.calls.contains(.health))
  }

  @Test("a reset while a probe is in flight drops its result")
  func resetDuringProbe() async {
    let (tester, fake) = make()
    let gate = await fake.hold(.health)
    tester.test(urlText: Self.url, tokenText: "t")
    await gate.waitUntilHeld()
    tester.reset()
    gate.release()
    await tester.settled()
    #expect(tester.outcome == nil)
  }

  @Test("a field edit that only trims whitespace keeps the result, another value drops it")
  func fieldsChanged() async {
    let (tester, _) = make()
    tester.test(urlText: "  \(Self.url)  ", tokenText: " t ", saved: true)
    await tester.settled()
    tester.fieldsChanged(urlText: Self.url, tokenText: "t")
    #expect(tester.outcome == .savedConnected)
    tester.fieldsChanged(urlText: Self.url, tokenText: "other")
    #expect(tester.outcome == nil)
  }
}
