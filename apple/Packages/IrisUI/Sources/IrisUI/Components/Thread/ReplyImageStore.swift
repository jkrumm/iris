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
/// of the store. A failure is remembered until ``load(_:)`` is asked again (tapping the placeholder does). At most
/// ``maxConcurrentLoads`` files are fetched at once, so a long reply full of diagrams does not open a request each.
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
  @ObservationIgnored private let maxConcurrentLoads: Int
  /// Loads holding a slot, and the loads waiting for one, oldest first.
  @ObservationIgnored private var activeLoads = 0
  @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

  public init(loader: any ReplyAssetLoader, maxConcurrentLoads: Int = 3) {
    self.loader = loader
    self.maxConcurrentLoads = max(maxConcurrentLoads, 1)
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

  /// Loads `ref` unless it is loaded or already loading; a previous failure is tried again. A caller that is cancelled (its
  /// view went away) cancels the load: one still waiting for a slot never fetches, and a caller that joined it and was not
  /// cancelled starts the load again.
  public func load(_ ref: ReplyAssetRef) async {
    while !Task.isCancelled, images[ref] == nil, !failed.contains(ref) {
      let task = inFlight[ref] ?? startLoad(ref)
      await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }

  private func startLoad(_ ref: ReplyAssetRef) -> Task<Void, Never> {
    failed.remove(ref)
    let loader = loader
    let task = Task { [weak self] in
      guard let self else { return }
      await acquireSlot()
      // Cancelled while waiting: the slot goes straight on and nothing is fetched.
      guard !Task.isCancelled else {
        releaseSlot()
        abandon(ref)
        return
      }
      let image: CGImage?
      do {
        image = await Self.decode(try await loader.data(for: ref))
      } catch {
        image = nil
      }
      releaseSlot()
      guard !Task.isCancelled else {
        abandon(ref)
        return
      }
      finish(ref, image: image)
    }
    inFlight[ref] = task
    return task
  }

  /// A cancelled load leaves no trace: not loaded, not failed, so the next ask starts it again.
  private func abandon(_ ref: ReplyAssetRef) {
    inFlight[ref] = nil
  }

  /// Takes a load slot, waiting for one to free up when all are taken. A freed slot passes straight to the oldest waiter.
  private func acquireSlot() async {
    if activeLoads < maxConcurrentLoads {
      activeLoads += 1
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  private func releaseSlot() {
    if waiting.isEmpty {
      activeLoads -= 1
    } else {
      waiting.removeFirst().resume()
    }
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
