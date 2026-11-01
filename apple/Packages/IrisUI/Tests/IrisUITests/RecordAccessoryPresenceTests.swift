import Testing

@testable import IrisUI

@MainActor
struct RecordAccessoryPresenceTests {
  @Test("the record control is hidden while any screen with bottom actions is shown")
  func hiddenWhileHeld() {
    let presence = RecordAccessoryPresence()
    #expect(!presence.isHidden)
    presence.enter()
    #expect(presence.isHidden)
    presence.leave()
    #expect(!presence.isHidden)
  }

  @Test("a push registers the new screen before the old one leaves: the control stays hidden between them")
  func overlappingScreens() {
    let presence = RecordAccessoryPresence()
    presence.enter()
    presence.enter()
    presence.leave()
    #expect(presence.isHidden)
    presence.leave()
    #expect(!presence.isHidden)
  }

  @Test("an unmatched leave never goes below zero")
  func unmatchedLeave() {
    let presence = RecordAccessoryPresence()
    presence.leave()
    presence.enter()
    #expect(presence.isHidden)
    presence.leave()
    #expect(!presence.isHidden)
  }
}
