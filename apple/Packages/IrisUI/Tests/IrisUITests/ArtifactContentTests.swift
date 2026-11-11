import Foundation
import SwiftUI
import Testing

@testable import IrisUI

/// The host side of an artifact with no web view: what a file becomes (page and payload), the Share file name, the live-island
/// budget and the file store.
@MainActor
struct ArtifactContentTests {
  private static func asset(
    _ kind: ArtifactBlock.Kind, format: ArtifactAsset.Format? = nil, title: String? = nil, assetID: String = "a1"
  ) -> ArtifactAsset {
    ArtifactAsset(
      ref: ReplyAssetRef(memoID: "m1", assetID: assetID), kind: kind, index: 0, title: title, format: format, bytes: 64)
  }

  private static func object(_ json: String?) throws -> [String: Any] {
    let data = try #require(json.map { Data($0.utf8) })
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("A show spec renders in the bundled page with the spec and the scheme in the payload")
  func showPayload() throws {
    let spec = Data(#"{"type":"table","columns":["A"],"rows":[[1]]}"#.utf8)
    let content = try #require(ArtifactContent(asset: Self.asset(.show), data: spec, scheme: .dark))
    #expect(content.entry == .bundled("index.html"))
    let payload = try Self.object(content.payloadJSON)
    let artifact = try #require(payload["artifact"] as? [String: Any])
    #expect(artifact["kind"] as? String == "show")
    #expect((artifact["spec"] as? [String: Any])?["type"] as? String == "table")
    #expect((payload["theme"] as? [String: Any])?["scheme"] as? String == "dark")
  }

  @Test("A file that is not a JSON object is no show spec")
  func badSpec() {
    #expect(ArtifactContent(asset: Self.asset(.show), data: Data("[1, 2]".utf8), scheme: .light) == nil)
    #expect(ArtifactContent(asset: Self.asset(.show), data: Data("not json".utf8), scheme: .light) == nil)
  }

  @Test("A markdown document goes to the renderer with its title; an HTML document is its own page with no payload")
  func documents() throws {
    let markdown = try #require(
      ArtifactContent(
        asset: Self.asset(.doc, format: .markdown, title: "Report"), data: Data("# Hi".utf8), scheme: .light))
    #expect(markdown.entry == .bundled("index.html"))
    let artifact = try #require(try Self.object(markdown.payloadJSON)["artifact"] as? [String: Any])
    #expect(artifact["format"] as? String == "markdown")
    #expect(artifact["title"] as? String == "Report")
    #expect(artifact["content"] as? String == "# Hi")

    let html = try #require(
      ArtifactContent(asset: Self.asset(.doc, format: .html), data: Data("<p>x</p>".utf8), scheme: .dark))
    #expect(html.entry == .html("<p>x</p>"))
    #expect(html.payloadJSON == nil)
  }

  @Test("Share files are named after the title with the format's extension")
  func exportNames() {
    let report = Self.asset(.doc, format: .markdown, title: "Week 12 / report")
    #expect(ArtifactExport.fileName(for: report) == "Week 12 - report.md")
    #expect(ArtifactExport.fileName(for: Self.asset(.doc, format: .html)) == "artifact-doc-1.html")
    #expect(ArtifactExport.fileName(for: Self.asset(.show, title: "Cost")) == "Cost.json")
  }

  @Test("The size line names the format and the file size")
  func detailLine() {
    let line = ArtifactLabels.detail(for: Self.asset(.doc, format: .html))
    #expect(line.hasPrefix("HTML · "))
  }

  @Test("At most three islands are live: the most recently shown; one that leaves frees its place")
  func budget() {
    let budget = ArtifactIslandBudget()
    for id in ["a", "b", "c", "d"] { budget.setVisible(id, true) }
    #expect(budget.liveCount == 3)
    #expect(!budget.isLive("a"))
    #expect(["b", "c", "d"].allSatisfy(budget.isLive))
    budget.setVisible("d", false)
    #expect(budget.isLive("a"))
    #expect(!budget.isLive("d"))
    budget.setVisible("a", true)
    #expect(budget.isLive("a") && budget.liveCount == 3)
  }

  private struct ScriptedLoader: ReplyAssetLoader {
    struct Failure: Error {}
    let calls: Calls

    final class Calls: @unchecked Sendable {
      // Tests only, touched from the main actor's tasks one at a time.
      var count = 0
      var fail = true
    }

    func data(for ref: ReplyAssetRef) async throws -> Data {
      calls.count += 1
      if calls.fail { throw Failure() }
      return Data("{}".utf8)
    }
  }

  @Test("The store remembers a failure until retry, and keeps a loaded file")
  func storeRetry() async {
    let calls = ScriptedLoader.Calls()
    let store = ArtifactStore(loader: ScriptedLoader(calls: calls))
    let ref = ReplyAssetRef(memoID: "m", assetID: "a")
    #expect(store.phase(for: ref) == .loading)
    await store.load(ref)
    #expect(store.phase(for: ref) == .failed)
    await store.load(ref)
    #expect(calls.count == 1)
    calls.fail = false
    await store.retry(ref)
    #expect(store.phase(for: ref) == .loaded(Data("{}".utf8)))
    await store.load(ref)
    #expect(calls.count == 2)
  }
}
