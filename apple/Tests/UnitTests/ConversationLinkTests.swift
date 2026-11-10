import Foundation
import IrisCore
import Testing

@Suite("ConversationLink")
struct ConversationLinkTests {
  private let id = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40"

  @Test("every focus survives build then parse", arguments: ComposerFocus.allCases)
  func roundTrip(focus: ComposerFocus) {
    let link = ConversationLink(memoID: id, focus: focus)
    #expect(ConversationLink(url: link.url) == link)
  }

  @Test("the built URL is iris://memo/<id>, with the focus only when there is one")
  func builtShape() {
    #expect(ConversationLink(memoID: id).url.absoluteString == "iris://memo/\(id)")
    #expect(ConversationLink(memoID: id, focus: .keyboard).url.absoluteString == "iris://memo/\(id)?focus=keyboard")
    #expect(ConversationLink(memoID: id, focus: .voice).url.absoluteString == "iris://memo/\(id)?focus=voice")
  }

  @Test("an unknown focus opens the conversation without one")
  func unknownFocus() {
    #expect(ConversationLink(url: url("iris://memo/\(id)?focus=hologram")) == ConversationLink(memoID: id))
  }

  @Test("other schemes, hosts, paths and empty ids are rejected")
  func rejected() {
    for text in [
      "https://memo/\(id)", "iris://settings/\(id)", "iris://memo", "iris://memo/", "iris://memo//",
      "iris://memo/\(id)/extra", "iris://memo/%20", "iris:///\(id)", "iris:memo/\(id)",
    ] {
      #expect(ConversationLink(url: url(text)) == nil, "\(text)")
    }
  }

  private func url(_ text: String) -> URL {
    URL(string: text) ?? URL(fileURLWithPath: "/")
  }
}
