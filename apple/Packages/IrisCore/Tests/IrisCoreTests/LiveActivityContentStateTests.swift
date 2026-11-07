import Foundation
import Testing

@testable import IrisCore

@Suite("LiveActivityContentState")
struct LiveActivityContentStateTests {
  @Test("the device-side timer fields survive a coding round trip")
  func roundTrip() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_030)
    let frozen = Date(timeIntervalSince1970: 1_800_000_090)
    let state = LiveActivityContentState(
      phase: .paused, hasReply: false, inputName: "iPhone", timerStart: start, timerFrozenAt: frozen)
    let data = try IrisJSON.makeEncoder().encode(state)
    #expect(try IrisJSON.makeDecoder().decode(LiveActivityContentState.self, from: data) == state)
  }

  @Test("a state without timer fields omits the keys and decodes the server's content-state to nil fields")
  func absentFields() throws {
    let encoded = try IrisJSON.makeEncoder().encode(LiveActivityContentState(phase: .done, hasReply: true))
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("timerStart") && !text.contains("timerFrozenAt"))

    let server = Data(#"{"phase":"done","routeChip":"Task","headline":"Plan","hasReply":true}"#.utf8)
    let decoded = try IrisJSON.makeDecoder().decode(LiveActivityContentState.self, from: server)
    #expect(decoded.timerStart == nil && decoded.timerFrozenAt == nil && decoded.inputName == nil)
  }
}
