import Foundation

/// One line of the working list; the index is its identity, so a repeated tool is a new row.
public struct ActivityLine: Equatable, Sendable, Identifiable {
  public let id: Int
  public let label: String

  public init(id: Int, label: String) {
    self.id = id
    self.label = label
  }
}

/// One block of a conversation as the screens draw it: what was said, the answer, an answer still on its way, a turn that failed.
/// The app derives these from the conversation's entries; ``ConversationTurnList`` renders them.
public struct ConversationTurn: Identifiable, Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    case user(String)
    /// The finished answer with its memo's Mermaid renders (by fence index) and artifacts (by kind and index).
    case assistant(String, mermaid: [Int: MermaidAsset], artifacts: [ArtifactAsset.Key: ArtifactAsset] = [:])
    case pending(StepProgress, caption: String)
    case failed(String)
    /// The answer is being worked on: one line per tool started, the last one is current.
    case working([ActivityLine])
    /// The answer as it streams; `activity` is the current tool's line, if any.
    case streaming(markdown: String, activity: String?)
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
