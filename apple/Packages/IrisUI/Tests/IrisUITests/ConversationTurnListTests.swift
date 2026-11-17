import SwiftUI
import Testing

@testable import IrisUI

@MainActor
struct ConversationTurnListTests {
  @Test("Copy on a long user turn puts the full text on the pasteboard, whatever its gist says")
  func copyIsTheFullText() {
    var copied: [String] = []
    let list = ConversationTurnList(
      turns: [], style: .phone, dayTitle: { _ in "" }, onCopy: { copied.append($0) })
    let full = String(repeating: "A long, sloppy dictation that goes on. ", count: 30)

    list.userCopy(.user(full, gist: "A short gist."))?()
    list.userCopy(.user(full))?()

    #expect(copied == [full, full])
    #expect(list.userCopy(.failed("x")) == nil)
  }

  @Test("a list without onCopy offers no Copy")
  func noCopy() {
    let list = ConversationTurnList(turns: [], style: .phone, dayTitle: { _ in "" })
    #expect(list.userCopy(.user("hi", gist: nil)) == nil)
  }
}
