import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import IrisUI

/// A loader that holds every request until the test lets it go, and records how many were open at once.
private final class GatedLoader: ReplyAssetLoader {
  private struct State {
    var open = 0
    var peak = 0
    var started: [ReplyAssetRef] = []
    var gates: [ReplyAssetRef: CheckedContinuation<Void, Never>] = [:]
  }
  private let state = Mutex(State())

  var peak: Int { state.withLock { $0.peak } }
  var started: [ReplyAssetRef] { state.withLock { $0.started } }

  func data(for ref: ReplyAssetRef) async throws -> Data {
    // The request counts as started only once its gate is in place, so a release can never miss it.
    await withCheckedContinuation { continuation in
      state.withLock {
        $0.open += 1
        $0.peak = max($0.peak, $0.open)
        $0.started.append(ref)
        $0.gates[ref] = continuation
      }
    }
    state.withLock { $0.open -= 1 }
    return Self.png
  }

  func release(_ ref: ReplyAssetRef) {
    let gate = state.withLock { $0.gates.removeValue(forKey: ref) }
    gate?.resume()
  }

  /// A 1 × 1 PNG.
  static let png: Data = {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    let data = NSMutableData()
    guard let image = context?.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }()
}

@MainActor
@Suite("ReplyImageStore")
struct ReplyImageStoreTests {
  private func ref(_ index: Int) -> ReplyAssetRef { ReplyAssetRef(memoID: "m", assetID: "a\(index)") }

  private func until(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<5_000 {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }

  @Test("at most the cap are fetched at once; a finished load hands its slot to a waiting one")
  func boundedConcurrency() async {
    let loader = GatedLoader()
    let store = ReplyImageStore(loader: loader, maxConcurrentLoads: 2)
    let refs = (0..<5).map(ref)
    let loads = refs.map { ref in Task { await store.load(ref) } }

    #expect(await until { loader.started.count == 2 })
    for _ in 0..<50 { await Task.yield() }
    #expect(loader.started.count == 2, "the others wait for a slot")

    loader.release(loader.started[0])
    #expect(await until { loader.started.count == 3 })

    var released = 1
    while released < refs.count {
      guard await until({ loader.started.count > released }) else { break }
      loader.release(loader.started[released])
      released += 1
    }
    for load in loads { await load.value }
    #expect(Set(loader.started) == Set(refs))
    #expect(loader.peak == 2)
    for ref in refs {
      guard case .loaded = store.phase(for: ref) else {
        Issue.record("\(ref.assetID) did not load")
        continue
      }
    }
  }

  @Test("asking for a file already loading joins that load")
  func singleFlightPerFile() async {
    let loader = GatedLoader()
    let store = ReplyImageStore(loader: loader)
    let first = Task { await store.load(ref(0)) }
    let second = Task { await store.load(ref(0)) }
    #expect(await until { loader.started.count == 1 })
    for _ in 0..<50 { await Task.yield() }
    #expect(loader.started.count == 1)
    loader.release(ref(0))
    await first.value
    await second.value
    #expect(loader.started.count == 1)
  }

  @Test("a load cancelled while it waits for a slot never fetches, and the file can be asked for again")
  func cancelledWhileWaiting() async {
    let loader = GatedLoader()
    let store = ReplyImageStore(loader: loader, maxConcurrentLoads: 1)
    let holder = Task { await store.load(ref(0)) }
    #expect(await until { loader.started.count == 1 })

    let waiter = Task { await store.load(ref(1)) }
    for _ in 0..<50 { await Task.yield() }
    waiter.cancel()
    loader.release(ref(0))
    await holder.value
    await waiter.value
    for _ in 0..<50 { await Task.yield() }
    #expect(loader.started == [ref(0)], "the cancelled load did not fetch")
    guard case .loading = store.phase(for: ref(1)) else {
      Issue.record("a cancelled load is neither loaded nor failed")
      return
    }

    let again = Task { await store.load(ref(1)) }
    #expect(await until { loader.started.count == 2 })
    loader.release(ref(1))
    await again.value
    guard case .loaded = store.phase(for: ref(1)) else {
      Issue.record("the retried load did not finish")
      return
    }
  }

  @Test("a caller that joined a load another caller cancelled starts it again")
  func joinerOutlivesACancelledOwner() async {
    let loader = GatedLoader()
    let store = ReplyImageStore(loader: loader)
    let owner = Task { await store.load(ref(0)) }
    #expect(await until { loader.started.count == 1 })
    let joiner = Task { await store.load(ref(0)) }
    for _ in 0..<50 { await Task.yield() }

    owner.cancel()
    loader.release(ref(0))
    await owner.value
    #expect(await until { loader.started.count == 2 }, "the joiner restarted the load")
    loader.release(ref(0))
    await joiner.value
    guard case .loaded = store.phase(for: ref(0)) else {
      Issue.record("the joiner did not get the image")
      return
    }
  }
}
