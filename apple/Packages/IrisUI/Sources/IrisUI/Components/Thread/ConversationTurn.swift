import Foundation

/// One block of a conversation as the screens draw it: what was said, the answer, an answer still on its way, a turn that failed.
/// The app derives these from the conversation's entries; ``ConversationTurnList`` renders them.
public struct ConversationTurn: Identifiable, Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    case user(String)
    case assistant(String, mermaid: [Int: MermaidAsset])
    case pending(StepProgress, caption: String)
    case failed(String)
  }

  public let id: String
  /// The memo the turn belongs to; `nil` for a reply held on this device, which is not a memo yet.
  public let memoID: String?
  public let date: Date?
  public let content: Content

  public init(id: String, memoID: String?, date: Date?, content: Content) {
    self.id = id
    self.memoID = memoID
    self.date = date
    self.content = content
  }
}
