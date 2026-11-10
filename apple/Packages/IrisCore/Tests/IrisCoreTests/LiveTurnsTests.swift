import Testing

@testable import IrisCore

@Suite("LiveTurns")
struct LiveTurnsTests {
  private func delta(_ seq: Int, _ text: String, attempt: Int = 1, id: String = "m") -> ServerEvent {
    .memoDelta(MemoDelta(id: id, attempt: attempt, seq: seq, text: text))
  }

  private func activity(_ tool: String, attempt: Int = 1, id: String = "m") -> ServerEvent {
    .memoActivity(MemoActivity(id: id, attempt: attempt, tool: tool))
  }

  @Test("deltas append and a replayed seq is dropped")
  func appends() {
    var live = LiveTurns()
    #expect(live.turn(for: "m") == nil)
    live.apply(delta(1, "Hel"))
    #expect(live.turn(for: "m")?.shownText == "Hel")
    live.apply(delta(2, "lo"))
    #expect(live.turn(for: "m")?.shownText == "Hello")
    live.apply(delta(2, "lo"))
    live.apply(delta(1, "Hel"))
    #expect(live.turn(for: "m")?.shownText == "Hello")
    #expect(live.turn(for: "m")?.seq == 2)
  }

  @Test("a new attempt resets text and tools")
  func newAttempt() {
    var live = LiveTurns()
    live.apply(activity("terminal"))
    live.apply(delta(1, "old"))
    live.apply(delta(1, "new", attempt: 2))
    #expect(live.turn(for: "m")?.shownText == "new")
    #expect(live.turn(for: "m")?.tools == [])
    live.apply(activity("web", attempt: 3))
    #expect(live.turn(for: "m")?.shownText == "")
    #expect(live.turn(for: "m")?.tools == ["web"])
  }

  @Test("ready forgets every turn")
  func ready() {
    var live = LiveTurns()
    live.apply(delta(1, "a", id: "x"))
    live.apply(activity("web", id: "y"))
    live.apply(.ready)
    #expect(live.turn(for: "x") == nil && live.turn(for: "y") == nil)
  }

  @Test("a mid-turn open hides the text until a seed fills the gap, then later deltas append")
  func midTurn() {
    var live = LiveTurns()
    live.apply(delta(5, "tail"))
    #expect(live.turn(for: "m")?.shownText == "")
    live.seed(memoID: "m", partial: PartialReply(attempt: 1, seq: 6, text: "partial"))
    #expect(live.turn(for: "m")?.shownText == "partial")
    live.apply(delta(6, "x"))
    live.apply(delta(3, "x"))
    #expect(live.turn(for: "m")?.shownText == "partial")
    live.apply(delta(7, "!"))
    #expect(live.turn(for: "m")?.shownText == "partial!")
  }

  @Test("a skipped delta opens a gap")
  func skipped() {
    var live = LiveTurns()
    live.apply(delta(1, "a"))
    live.apply(delta(3, "c"))
    #expect(live.turn(for: "m")?.shownText == "")
  }

  @Test("a seed with a lower seq keeps ours; a seed of another attempt replaces; no partial is a no-op")
  func seeds() {
    var live = LiveTurns()
    live.seed(memoID: "m", partial: nil)
    #expect(live.turn(for: "m") == nil)
    live.apply(activity("web"))
    live.apply(delta(1, "a"))
    live.apply(delta(2, "b"))
    live.seed(memoID: "m", partial: PartialReply(attempt: 1, seq: 1, text: "a"))
    #expect(live.turn(for: "m")?.shownText == "ab")
    live.seed(memoID: "m", partial: PartialReply(attempt: 1, seq: 2, text: "AB"))
    #expect(live.turn(for: "m")?.shownText == "AB")
    #expect(live.turn(for: "m")?.tools == ["web"])
    live.seed(memoID: "m", partial: PartialReply(attempt: 2, seq: 4, text: "other"))
    #expect(live.turn(for: "m")?.shownText == "other")
    #expect(live.turn(for: "m")?.tools == [])
    live.seed(memoID: "n", partial: PartialReply(attempt: 1, seq: 2, text: "fresh"))
    #expect(live.turn(for: "n")?.shownText == "fresh")
  }

  @Test("activity comes before text; tools keep their order, repeats included")
  func tools() {
    var live = LiveTurns()
    live.apply(activity("terminal"))
    #expect(live.turn(for: "m")?.shownText == "")
    live.apply(activity("web"))
    live.apply(activity("terminal"))
    #expect(live.turn(for: "m")?.tools == ["terminal", "web", "terminal"])
    #expect(live.turn(for: "m")?.currentTool == "terminal")
    live.apply(delta(1, "hi"))
    #expect(live.turn(for: "m")?.tools.count == 3)
    #expect(live.turn(for: "m")?.shownText == "hi")
    live.drop(memoID: "m")
    #expect(live.turn(for: "m") == nil)
  }
}
