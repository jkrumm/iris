import Foundation

/// Which input the conversation screen puts forward when it opens.
public enum ComposerFocus: String, Sendable, Equatable, CaseIterable {
  /// Nothing: the conversation just opens.
  case none
  /// The reply field is focused with the keyboard up.
  case keyboard
  /// A voice reply starts (handled where the take starts, not by the conversation screen).
  case voice
}

/// The deep link `iris://memo/<id>[?focus=keyboard|voice]`: the notification's actions, the Live Activity's buttons and card
/// build it, the app parses it. Compiled into the widget extension through IrisCore, which has no app-only code.
public struct ConversationLink: Sendable, Equatable {
  public static let scheme = "iris"
  private static let host = "memo"
  private static let focusKey = "focus"

  public let memoID: String
  public let focus: ComposerFocus

  public init(memoID: String, focus: ComposerFocus = .none) {
    self.memoID = memoID
    self.focus = focus
  }

  /// `nil` for any other scheme, host or path shape, and for an empty id. An unknown `focus` value opens the conversation
  /// without focus rather than refusing the link.
  public init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == Self.host
    else { return nil }
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard parts.count == 1, let id = parts.first, !id.isEmpty, !id.allSatisfy(\.isWhitespace) else { return nil }
    let value = components.queryItems?.first { $0.name == Self.focusKey }?.value
    self.init(memoID: String(id), focus: value.flatMap(ComposerFocus.init(rawValue:)) ?? .none)
  }

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.host
    components.path = "/" + memoID
    if focus != .none { components.queryItems = [URLQueryItem(name: Self.focusKey, value: focus.rawValue)] }
    return components.url ?? URL(fileURLWithPath: "/")
  }
}
