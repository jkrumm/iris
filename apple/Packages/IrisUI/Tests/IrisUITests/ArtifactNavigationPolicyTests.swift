import Foundation
import Testing

@testable import IrisUI

struct ArtifactNavigationPolicyTests {
  private static let scheme = "iris-artifact"

  fileprivate struct Case: CustomTestStringConvertible, Sendable {
    let url: String?
    let linkActivation: Bool
    let mainFrame: Bool
    let expected: ArtifactNavigationPolicy.Decision

    init(
      _ url: String?, link: Bool = false, mainFrame: Bool = true, _ expected: ArtifactNavigationPolicy.Decision
    ) {
      self.url = url
      self.linkActivation = link
      self.mainFrame = mainFrame
      self.expected = expected
    }

    var testDescription: String {
      "\(url ?? "nil") link=\(linkActivation) main=\(mainFrame) -> \(expected)"
    }
  }

  private static func external(_ text: String) -> ArtifactNavigationPolicy.Decision {
    .openExternally(URL(string: text)!)
  }

  private static let cases: [Case] = [
    // The island's own content and the blank page load.
    Case("iris-artifact://app/island.html", .allow),
    Case("iris-artifact://doc/page", .allow),
    Case("IRIS-ARTIFACT://app/island.html", .allow),
    Case("iris-artifact://app/island.html", link: true, .allow),
    Case("iris-artifact://app/island.html", mainFrame: false, .allow),
    Case("about:blank", .allow),
    Case("about:srcdoc", .cancel),
    // A followed link leaves; the page stays.
    Case("https://example.com/docs", link: true, external("https://example.com/docs")),
    Case("http://example.com/", link: true, external("http://example.com/")),
    Case("mailto:someone@example.com", link: true, external("mailto:someone@example.com")),
    Case("tel:+10000000000", link: true, external("tel:+10000000000")),
    // Anything else that reaches the network is refused: script, redirect, form, window.open.
    Case("https://example.com/", .cancel),
    Case("http://example.com/", .cancel),
    Case("mailto:someone@example.com", .cancel),
    Case("tel:+10000000000", .cancel),
    // A subframe never opens anything outside.
    Case("https://example.com/docs", link: true, mainFrame: false, .cancel),
    // Every other scheme.
    Case("file:///etc/hosts", .cancel),
    Case("file:///etc/hosts", link: true, .cancel),
    Case("javascript:alert(1)", .cancel),
    Case("javascript:alert(1)", link: true, .cancel),
    Case("data:text/html,hi", .cancel),
    Case("data:text/html,hi", link: true, .cancel),
    Case("blob:https://example.com/id", .cancel),
    Case("blob:https://example.com/id", link: true, .cancel),
    Case("ftp://example.com/file", .cancel),
    Case("ftp://example.com/file", link: true, .cancel),
    Case("someapp://open", link: true, .cancel),
    Case("someapp://open", .cancel),
    // No URL at all.
    Case(nil, .cancel),
    Case(nil, link: true, .cancel),
  ]

  @Test("Decision matrix", arguments: cases)
  fileprivate func decides(_ item: Case) {
    let url = item.url.flatMap { URL(string: $0) }
    let decision = ArtifactNavigationPolicy.decide(
      url: url, isLinkActivation: item.linkActivation, island: Self.scheme, isMainFrame: item.mainFrame)
    #expect(decision == item.expected)
  }

  @Test("A navigation to an http(s) URL never loads inside the island")
  func httpNeverAllowed() {
    for text in ["http://example.com/", "https://example.com/"] {
      for link in [true, false] {
        let decision = ArtifactNavigationPolicy.decide(
          url: URL(string: text), isLinkActivation: link, island: Self.scheme)
        #expect(decision != .allow)
      }
    }
  }
}
