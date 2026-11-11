import Foundation
import IrisCore
import IrisUI

extension Memo {
  /// A memo that continues another memo's session (`threadId != id`): the History row's thread marker. `act` gives every Hermes
  /// memo its own session id as `threadId`, so a memo in its own session, or without a thread, is not marked.
  nonisolated var continuesThread: Bool {
    guard let threadId, !isDeleted else { return false }
    return threadId != id
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

  /// The memo's reply artifacts (charts, tables, documents) keyed by kind and per-kind fence index.
  nonisolated var artifactAssets: [ArtifactAsset.Key: ArtifactAsset] {
    var assets: [ArtifactAsset.Key: ArtifactAsset] = [:]
    for artifact in replyArtifacts {
      let kind: ArtifactBlock.Kind = artifact.kind == .show ? .show : .doc
      let format: ArtifactAsset.Format? =
        switch artifact.format {
        case .markdown: .markdown
        case .html: .html
        case nil: nil
        }
      let asset = ArtifactAsset(
        ref: ReplyAssetRef(memoID: id, assetID: artifact.assetId), kind: kind, index: artifact.index,
        title: artifact.title, format: format, bytes: artifact.bytes)
      assets[asset.key] = asset
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

extension ConversationTurn {
  /// The turn of a conversation entry: the answer carries its memo's Mermaid renders and artifacts, a pending one the pipeline's progress.
  init(_ entry: ConversationEntry) {
    let content: Content =
      switch entry.kind {
      case .user(let text): .user(text)
      case .reply(let markdown):
        .assistant(markdown, mermaid: entry.memo.mermaidAssets, artifacts: entry.memo.artifactAssets)
      case .pending: .pending(entry.memo.stepProgress, caption: entry.memo.pendingCaption)
      case .failed(let error):
        .failed(error ?? String(localized: "This turn failed.", comment: "Failed turn in a thread"))
      }
    self.init(id: entry.id, memoID: entry.memo.id, date: entry.date, content: content)
  }
}
