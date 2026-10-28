import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI

/// One server-rendered file of a reply: `GET /v1/memos/:memoID/assets/:assetID`.
public struct ReplyAssetRef: Hashable, Sendable {
  public var memoID: String
  public var assetID: String

  public init(memoID: String, assetID: String) {
    self.memoID = memoID
    self.assetID = assetID
  }
}

/// A rendered Mermaid diagram: the PNG for each appearance and its size in points (the PNG is drawn at 2x).
public struct MermaidAsset: Hashable, Sendable {
  public var light: ReplyAssetRef
  public var dark: ReplyAssetRef
  public var width: Int
  public var height: Int

  public init(light: ReplyAssetRef, dark: ReplyAssetRef, width: Int, height: Int) {
    self.light = light
    self.dark = dark
    self.width = width
    self.height = height
  }

  public func ref(for scheme: ColorScheme) -> ReplyAssetRef { scheme == .dark ? dark : light }

  var aspectRatio: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 1 }
}

/// Where a reply's image bytes come from. The app's implementation is the authenticated, disk-cached media path.
public protocol ReplyAssetLoader: Sendable {
  func data(for ref: ReplyAssetRef) async throws -> Data
}

/// Decoded reply images for the thread screen: each file is loaded once, in flight at most once, and kept for the life
/// of the store. A failure is remembered until ``load(_:)`` is asked again (tapping the placeholder does).
@MainActor
@Observable
public final class ReplyImageStore {
  public enum Phase {
    case loading
    case loaded(CGImage)
    case failed
  }

  private var images: [ReplyAssetRef: CGImage] = [:]
  private var failed: Set<ReplyAssetRef> = []
  private var inFlight: [ReplyAssetRef: Task<Void, Never>] = [:]
  @ObservationIgnored private let loader: any ReplyAssetLoader

  public init(loader: any ReplyAssetLoader) {
    self.loader = loader
  }

  public func phase(for ref: ReplyAssetRef) -> Phase {
    if let image = images[ref] { return .loaded(image) }
    return failed.contains(ref) ? .failed : .loading
  }

  /// A decoded image the store already holds (snapshot tests, previews).
  public func seed(_ image: CGImage, for ref: ReplyAssetRef) {
    images[ref] = image
    failed.remove(ref)
  }

  /// Loads `ref` unless it is loaded or already loading; a previous failure is tried again.
  public func load(_ ref: ReplyAssetRef) async {
    if images[ref] != nil { return }
    if let running = inFlight[ref] {
      await running.value
      return
    }
    failed.remove(ref)
    let loader = loader
    let task = Task { [weak self] in
      let image: CGImage?
      do {
        image = await Self.decode(try await loader.data(for: ref))
      } catch {
        image = nil
      }
      guard !Task.isCancelled else { return }
      self?.finish(ref, image: image)
    }
    inFlight[ref] = task
    await task.value
  }

  private func finish(_ ref: ReplyAssetRef, image: CGImage?) {
    inFlight[ref] = nil
    if let image { images[ref] = image } else { failed.insert(ref) }
  }

  private nonisolated static func decode(_ data: Data) async -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

extension EnvironmentValues {
  /// The images of the reply being shown; `nil` shows every diagram as unavailable.
  @Entry public var replyImageStore: ReplyImageStore?
}
