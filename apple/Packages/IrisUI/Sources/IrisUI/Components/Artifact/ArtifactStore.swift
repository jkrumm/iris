import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// The files of a conversation's artifacts (a show spec's JSON, a document): each one fetched once through the app's
/// ``ReplyAssetLoader`` (the authenticated, disk-cached media path; the web view never loads anything itself), in flight at most
/// once, and kept for the life of the store. A failure is remembered until ``retry(_:)`` or ``load(_:)`` asks again.
@MainActor
@Observable
public final class ArtifactStore {
  public enum Phase: Equatable {
    case loading
    case loaded(Data)
    case failed
  }

  private var files: [ReplyAssetRef: Data] = [:]
  private var failed: Set<ReplyAssetRef> = []
  @ObservationIgnored private var inFlight: [ReplyAssetRef: Task<Void, Never>] = [:]
  @ObservationIgnored private let loader: any ReplyAssetLoader

  public init(loader: any ReplyAssetLoader) {
    self.loader = loader
  }

  public func phase(for ref: ReplyAssetRef) -> Phase {
    if let data = files[ref] { return .loaded(data) }
    return failed.contains(ref) ? .failed : .loading
  }

  /// A file the store already holds (snapshot runs, previews).
  public func seed(_ data: Data, for ref: ReplyAssetRef) {
    files[ref] = data
    failed.remove(ref)
  }

  /// Loads `ref` unless it is loaded, loading or failed. A load is shared: a caller that goes away does not cancel it for others.
  public func load(_ ref: ReplyAssetRef) async {
    guard files[ref] == nil, !failed.contains(ref) else { return }
    let task = inFlight[ref] ?? start(ref)
    await task.value
  }

  /// Forgets a failure (or a file the page refused) and loads `ref` again.
  public func retry(_ ref: ReplyAssetRef) async {
    guard inFlight[ref] == nil else { return await load(ref) }
    files[ref] = nil
    failed.remove(ref)
    await load(ref)
  }

  private func start(_ ref: ReplyAssetRef) -> Task<Void, Never> {
    let loader = loader
    let task = Task { [weak self] in
      let data = try? await loader.data(for: ref)
      self?.finish(ref, data: data)
    }
    inFlight[ref] = task
    return task
  }

  private func finish(_ ref: ReplyAssetRef, data: Data?) {
    inFlight[ref] = nil
    if let data { files[ref] = data } else { failed.insert(ref) }
  }
}

/// Keeps at most ``maxLive`` inline artifact islands alive in one conversation: the ones on screen, the most recently shown
/// first. An island that leaves the screen (or loses its place to a newer one) is shown as the snapshot it left behind, and
/// is revived when it scrolls back in. One budget per conversation screen.
@MainActor
@Observable
public final class ArtifactIslandBudget {
  public static let defaultMaxLive = 3

  public let maxLive: Int
  /// On-screen islands, oldest arrival first.
  private var visible: [String] = []
  private var snapshots: [String: CGImage] = [:]

  public init(maxLive: Int = ArtifactIslandBudget.defaultMaxLive) {
    self.maxLive = max(1, maxLive)
  }

  /// The island `id` came on screen or left it.
  public func setVisible(_ id: String, _ isVisible: Bool) {
    visible.removeAll { $0 == id }
    if isVisible { visible.append(id) }
  }

  /// `id` may hold a live web view now.
  public func isLive(_ id: String) -> Bool {
    visible.suffix(maxLive).contains(id)
  }

  /// How many islands are live.
  public var liveCount: Int { min(visible.count, maxLive) }

  public func snapshot(for id: String) -> CGImage? { snapshots[id] }

  public func store(_ image: CGImage, for id: String) {
    snapshots[id] = image
  }
}

extension EnvironmentValues {
  /// The artifact files of the conversation being shown; `nil` shows every artifact fence as code.
  @Entry public var artifactStore: ArtifactStore?
  /// The live-island budget of the conversation being shown; `nil` keeps every island live (a screen with one artifact).
  @Entry public var artifactIslandBudget: ArtifactIslandBudget?
  /// Opens an artifact's viewer (the Mac opens a window); `nil` presents it over the screen.
  @Entry public var openArtifact: OpenArtifactAction?
}

/// What `\.openArtifact` holds: called like a function, `openArtifact(request)`.
public struct OpenArtifactAction {
  private let handler: @MainActor (ArtifactViewerRequest) -> Void

  public init(_ handler: @escaping @MainActor (ArtifactViewerRequest) -> Void) {
    self.handler = handler
  }

  @MainActor public func callAsFunction(_ request: ArtifactViewerRequest) {
    handler(request)
  }
}
