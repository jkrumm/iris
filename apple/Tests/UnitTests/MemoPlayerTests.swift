import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("MemoPlayer")
struct MemoPlayerTests {
  @Test("seeking clamps into the clip and skip-back rewinds ten seconds, never below the start")
  func seekAndSkipBack() {
    let player = MemoPlayer(duration: 38)
    player.seek(to: 25)
    #expect(player.position == 25)
    player.skipBack()
    #expect(player.position == 15)
    player.skipBack()
    player.skipBack()
    #expect(player.position == 0)
    player.seek(to: 500)
    #expect(player.position == 38)
    player.seek(to: -4)
    #expect(player.position == 0)
  }

  @Test("with nothing loaded it neither plays nor claims to")
  func nothingLoaded() {
    let player = MemoPlayer(duration: 10)
    player.play()
    #expect(!player.isPlaying)
    #expect(!player.isLoaded)
    player.load(nil)
    #expect(!player.isLoaded)
  }

  @Test("a loaded clip starts at zero and pauses cleanly")
  func loadedClip() {
    let memo = MemoFactory.memo("p", audioSeconds: 3)
    let player = MemoPlayer(duration: 3)
    player.load(FakeMediaSource().audio(for: memo))
    #expect(player.isLoaded)
    #expect(player.position == 0)
    player.play()
    #expect(player.isPlaying)
    player.pause()
    #expect(!player.isPlaying)
  }
}

@Suite("MemoMediaSource")
struct MemoMediaSourceTests {
  private let spoken = MemoSummary(headline: "h", detail: "d", spoken: "s")

  @Test("the fake writes a silent clip of the memo's length")
  func fakeClip() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-media-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = FakeMediaSource(directory: directory)
    let request = try #require(source.audio(for: MemoFactory.memo("a", audioSeconds: 2)))
    let bytes = try Data(contentsOf: request.url)
    #expect(bytes.count == 44 + 2 * 8_000)
    #expect(bytes.prefix(4) == Data("RIFF".utf8))
    #expect(request.headers.isEmpty)
  }

  @Test("a typed memo has no recording; speech needs a reply")
  func availability() {
    let source = FakeMediaSource()
    #expect(source.audio(for: MemoFactory.memo("t", typed: true)) == nil)
    #expect(source.audio(for: MemoFactory.memo("r", state: .receiving)) == nil)
    #expect(source.speech(for: MemoFactory.memo("n")) == nil)
    #expect(source.speech(for: MemoFactory.memo("y", replyText: "ok")) != nil)
    #expect(source.speech(for: MemoFactory.memo("s", summary: spoken)) != nil)
  }

  @Test("the authenticated source points at the memo's media routes with the bearer token")
  func authenticated() throws {
    let source = AuthenticatedMediaSource(
      baseURL: try #require(URL(string: "https://example.com")), bearerToken: "token")
    let audio = try #require(source.audio(for: MemoFactory.memo("abc")))
    #expect(audio.url.absoluteString == "https://example.com/v1/memos/abc/audio")
    #expect(audio.headers == ["Authorization": "Bearer token"])
    let speech = try #require(source.speech(for: MemoFactory.memo("abc", replyText: "ok")))
    #expect(speech.url.path == "/v1/memos/abc/speech")
    #expect(source.speech(for: MemoFactory.memo("abc")) == nil)
  }
}
