import Foundation
import IrisCore
import IrisUI

extension Memo {
  /// A memo that belongs to a thread opens its conversation: every Hermes memo ran in a session, so the thread view is
  /// the one way to read it. A memo without a thread (a transcript, one that failed before `act`) keeps the plain detail.
  nonisolated var opensThread: Bool {
    threadId != nil && !isDeleted
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
