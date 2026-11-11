import Foundation

/// A typed artifact the server stored for a reply (`replyArtifacts`): an `iris-show` spec or an `iris-doc` document, fetched as
/// a file through `ref` (`GET /v1/memos/:memoID/assets/:assetID`).
public struct ArtifactAsset: Hashable, Sendable, Codable {
  public enum Format: String, Hashable, Sendable, Codable {
    case markdown
    case html
  }

  /// Which fence of the reply an artifact belongs to: its kind and its index among the fences of that kind.
  public struct Key: Hashable, Sendable {
    public var kind: ArtifactBlock.Kind
    public var index: Int

    public init(kind: ArtifactBlock.Kind, index: Int) {
      self.kind = kind
      self.index = index
    }
  }

  public var ref: ReplyAssetRef
  public var kind: ArtifactBlock.Kind
  public var index: Int
  public var title: String?
  /// Set on a document only.
  public var format: Format?
  /// The size of the stored file.
  public var bytes: Int

  public init(
    ref: ReplyAssetRef, kind: ArtifactBlock.Kind, index: Int, title: String? = nil, format: Format? = nil, bytes: Int
  ) {
    self.ref = ref
    self.kind = kind
    self.index = index
    self.title = title
    self.format = format
    self.bytes = bytes
  }

  public var key: Key { Key(kind: kind, index: index) }

  /// The format a document is in; a show spec is JSON.
  var fileExtension: String {
    switch (kind, format) {
    case (.show, _): "json"
    case (.doc, .html): "html"
    case (.doc, _): "md"
    }
  }
}

/// What the viewer opens: the artifact and its fence as written (shown as code when the file cannot be shown).
public struct ArtifactViewerRequest: Hashable, Sendable, Codable {
  public var asset: ArtifactAsset
  public var source: String

  public init(asset: ArtifactAsset, source: String) {
    self.asset = asset
    self.source = source
  }
}
