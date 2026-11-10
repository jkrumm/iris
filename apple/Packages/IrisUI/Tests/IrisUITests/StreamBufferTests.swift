import Testing

@testable import IrisUI

struct StreamBufferTests {
  private func ms(_ value: Int) -> Duration { .milliseconds(value) }

  @Test("the first offer publishes at once")
  func first() {
    var buffer = StreamBuffer()
    #expect(buffer.offer("a", at: ms(0)) == .publish("a"))
  }

  @Test("text that arrives within 80 ms waits for the deadline, text after it publishes")
  func interval() {
    var buffer = StreamBuffer()
    _ = buffer.offer("a", at: ms(0))
    #expect(buffer.offer("ab", at: ms(10)) == .wait(until: ms(80)))
    #expect(buffer.offer("abc", at: ms(79)) == .wait(until: ms(80)))
    #expect(buffer.offer("abcd", at: ms(80)) == .publish("abcd"))
    #expect(buffer.offer("abcde", at: ms(100)) == .wait(until: ms(160)))
  }

  @Test("a new line publishes after 16 ms, earlier it waits for 16 ms")
  func newline() {
    var buffer = StreamBuffer()
    _ = buffer.offer("a", at: ms(0))
    #expect(buffer.offer("a\n", at: ms(5)) == .wait(until: ms(16)))
    #expect(buffer.offer("a\nb", at: ms(16)) == .publish("a\nb"))
    #expect(buffer.offer("a\nb c", at: ms(20)) == .wait(until: ms(96)))
  }

  @Test("a newline already published is not a new line")
  func publishedNewline() {
    var buffer = StreamBuffer()
    _ = buffer.offer("a\n", at: ms(0))
    #expect(buffer.offer("a\nb", at: ms(20)) == .wait(until: ms(80)))
  }

  @Test("text that is not an extension of the published one counts as a change with a new line")
  func rewritten() {
    var buffer = StreamBuffer()
    _ = buffer.offer("abc", at: ms(0))
    #expect(buffer.offer("xyz", at: ms(20)) == .publish("xyz"))
  }

  @Test("publishing at the deadline restarts the interval, and offering the published text again is a no-op")
  func deadline() {
    var buffer = StreamBuffer()
    _ = buffer.offer("a", at: ms(0))
    _ = buffer.offer("ab", at: ms(10))
    #expect(buffer.publish("ab", at: ms(80)) == .publish("ab"))
    #expect(buffer.published == "ab")
    #expect(buffer.offer("ab", at: ms(90)) == .publish("ab"))
    #expect(buffer.offer("abc", at: ms(100)) == .wait(until: ms(160)))
  }
}
