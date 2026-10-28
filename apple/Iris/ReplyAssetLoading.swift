import Foundation
import IrisCore
import IrisUI

/// Fetches a reply's images through the same authenticated, disk-cached media path as the audio: the request comes
/// from the media source for the connection saved right now, and an asset id never changes content, so the file is kept.
struct MediaAssetLoader: ReplyAssetLoader {
  enum LoadError: Error {
    case unavailable
  }

  let source: @MainActor @Sendable () -> any MemoMediaSource
  let downloader: MediaDownloader

  func data(for ref: ReplyAssetRef) async throws -> Data {
    guard let request = await source().asset(memoID: ref.memoID, assetID: ref.assetID) else {
      throw LoadError.unavailable
    }
    let file = try await downloader.localURL(for: request)
    return try Data(contentsOf: file)
  }
}
