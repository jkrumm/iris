import Foundation

/// What an island may navigate to. The page itself is the only thing that ever loads inside it: a link leaves for the system's
/// handler, anything a script, redirect or form starts is refused.
enum ArtifactNavigationPolicy {
  enum Decision: Equatable {
    case allow
    case cancel
    case openExternally(URL)
  }

  private static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

  /// - Parameters:
  ///   - isLinkActivation: The navigation is the user following a link (`WKNavigationType.linkActivated`).
  ///   - scheme: The island's own URL scheme.
  ///   - isMainFrame: A subframe may only load the island's own content, it never opens anything outside.
  static func decide(url: URL?, isLinkActivation: Bool, island scheme: String, isMainFrame: Bool = true) -> Decision {
    guard let url, let urlScheme = url.scheme?.lowercased() else { return .cancel }
    if urlScheme == scheme.lowercased() { return .allow }
    if urlScheme == "about", url.absoluteString == "about:blank" { return .allow }
    guard isMainFrame, isLinkActivation, externalSchemes.contains(urlScheme) else { return .cancel }
    return .openExternally(url)
  }
}
