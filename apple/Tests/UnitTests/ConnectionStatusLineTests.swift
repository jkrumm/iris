import Testing

@testable import Iris

@Suite("ConnectionStatusLine")
struct ConnectionStatusLineTests {
  @Test("Connected only while the live traffic does not contradict the probe")
  func connectedNeedsALiveLink() {
    #expect(ConnectionStatusLine(connection: .connected, link: .unknown).title == "Connected")
    #expect(ConnectionStatusLine(connection: .connected, link: .live).tone == .good)

    let dropped = ConnectionStatusLine(connection: .connected, link: .unreachable)
    #expect(dropped.title == "Unreachable")
    #expect(dropped.tone == .bad)
    #expect(dropped.hint == "Server not reachable — is Tailscale on?")
  }

  @Test("a refused token is told apart from a server that cannot be reached")
  func rejectedToken() {
    let line = ConnectionStatusLine(connection: .connected, link: .rejected)
    #expect(line.title == "Token rejected")
    #expect(line.hint?.contains("token") == true)
  }

  @Test("a failed probe is overruled by traffic that got an answer since")
  func staleProbe() {
    #expect(ConnectionStatusLine(connection: .unreachable, link: .live).title == "Connected")
    #expect(ConnectionStatusLine(connection: .unreachable, link: .unknown).hint != nil)
  }

  @Test("nothing saved is not a reachability question")
  func notConfigured() {
    for link in [ServerLink.unknown, .live, .unreachable, .rejected] {
      let line = ConnectionStatusLine(connection: .notConfigured, link: link)
      #expect(line.title == "Not configured")
      #expect(line.hint == nil)
    }
  }

  @Test("checking and degraded keep their own words")
  func otherStates() {
    #expect(ConnectionStatusLine(connection: .checking, link: .unknown).title == "Checking…")
    #expect(ConnectionStatusLine(connection: .degraded(["hermes"]), link: .live).title == "Degraded · hermes")
  }
}
