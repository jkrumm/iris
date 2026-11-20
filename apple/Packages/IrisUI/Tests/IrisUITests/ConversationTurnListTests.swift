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

  @Test("a day is named once: later exchanges of the same calendar day get a plain line")
  func oneDayLinePerDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    func user(_ id: String, _ iso: String?) -> ConversationTurn {
      ConversationTurn(
        id: id, memoID: id, date: iso.flatMap { ISO8601DateFormatter().date(from: $0) }, content: .user("q"))
    }
    func reply(_ id: String, _ iso: String) -> ConversationTurn {
      ConversationTurn(
        id: id, memoID: id, date: ISO8601DateFormatter().date(from: iso),
        content: .assistant("a", mermaid: [:]))
    }
    let turns = [
      user("a.user", "2026-11-18T08:00:00Z"), reply("a.reply", "2026-11-18T08:01:00Z"),
      user("b.user", "2026-11-20T08:28:00Z"), reply("b.reply", "2026-11-20T08:28:30Z"),
      user("c.user", "2026-11-20T08:28:40Z"), reply("c.reply", "2026-11-20T08:29:00Z"),
      user("d.user", "2026-11-21T09:00:00Z"),
    ]
    let lines = ConversationTurnList.exchangeLines(of: turns, calendar: calendar)
    #expect(lines == ["b.user": true, "c.user": false, "d.user": true])
    #expect(lines.values.filter { $0 }.count == 2, "one named line per day change: the 20th once, the 21st once")
    #expect(
      ConversationTurnList.exchangeLines(of: [user("x", nil), user("y", nil)], calendar: calendar) == ["y": false])
  }

  @Test("a list without onCopy offers no Copy")
  func noCopy() {
    let list = ConversationTurnList(turns: [], style: .phone, dayTitle: { _ in "" })
    #expect(list.userCopy(.user("hi", gist: nil)) == nil)
  }
}
