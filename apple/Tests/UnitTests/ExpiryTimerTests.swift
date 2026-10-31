import Testing

@testable import Iris

@MainActor
@Suite("ExpiryTimer")
struct ExpiryTimerTests {
  @Test("it fires once after the duration")
  func fires() async {
    let timer = ExpiryTimer(sleep: { _ in })
    var fired = 0
    timer.arm(after: .seconds(1)) { fired += 1 }
    for _ in 0..<50 where fired == 0 { await Task.yield() }
    #expect(fired == 1)
  }

  @Test("arming again cancels the earlier timer, and cancel() stops a pending one")
  func replacedAndCancelled() async throws {
    let timer = ExpiryTimer(sleep: { try await Task.sleep(for: $0) })
    var fired: [String] = []
    timer.arm(after: .milliseconds(50)) { fired.append("first") }
    timer.arm(after: .milliseconds(100)) { fired.append("second") }
    try await Task.sleep(for: .milliseconds(250))
    #expect(fired == ["second"])

    timer.arm(after: .milliseconds(50)) { fired.append("third") }
    timer.cancel()
    try await Task.sleep(for: .milliseconds(150))
    #expect(fired == ["second"])
  }
}
