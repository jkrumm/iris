import Foundation
import IrisCore
import IrisUI

extension Memo {
  /// A memo that continues a conversation opens it. `act` gives every Hermes memo its own session id as `threadId`, so a memo
  /// in its own session (`threadId == id`: one answer, Retry, waterfall, kind chip and actions line) and one without a thread
  /// (a transcript, one that failed before `act`) keep the plain detail; only a turn into another memo's session
  /// (`threadId != id`) pushes the thread view, which is the server's `thread=true` (a conversation, two or more memos).
  nonisolated var opensThread: Bool {
    guard let threadId, !isDeleted else { return false }
    return threadId != id
  }

  /// The route History pushes for this memo, when it opens a thread.
  var threadRoute: ThreadRoute? {
    threadId.map { ThreadRoute(id: $0, title: summary?.headline ?? transcript) }
  }

  /// The memo's rendered Mermaid blocks keyed by fence index, as the PNGs of both appearances.
  nonisolated var mermaidAssets: [Int: MermaidAsset] {
    var assets: [Int: MermaidAsset] = [:]
    for block in replyBlocks where block.kind == .mermaid {
      assets[block.index] = MermaidAsset(
        light: ReplyAssetRef(memoID: id, assetID: block.png.light),
        dark: ReplyAssetRef(memoID: id, assetID: block.png.dark), width: block.width, height: block.height)
    }
    return assets
  }

  /// What the pending answer says while the pipeline is before `act`.
  var pendingCaption: String {
    switch state {
    case .receiving: String(localized: "Receiving the recording…", comment: "Pending answer in a thread")
    case .received: String(localized: "Transcribing…", comment: "Pending answer in a thread")
    case .transcribed, .routed: String(localized: "Asking Hermes…", comment: "Pending answer in a thread")
    default: String(localized: "Working…", comment: "Pending answer in a thread")
    }
  }
}
