import Foundation
import SwiftUI
import Testing
import WebKit

@testable import IrisUI

/// Real `WebPage`s (macOS host): the bundled page, the scheme handler, the CSP, the navigation decider and the bridge, with no view attached.
@MainActor
@Suite(.serialized)
struct ArtifactIslandTests {
  /// Collects what the island handed to `openExternal`.
  private final class Opened {
    var urls: [URL] = []
  }

  private func makeIsland(
    _ entry: ArtifactEntry = .bundled("island.html"), payload: any Encodable = IslandSamplePayload.sample,
    scheme: ColorScheme = .light, id: String? = nil, opened: Opened = Opened()
  ) throws -> ArtifactIsland {
    let encoded = try JSONEncoder().encode(payload)
    let json = try #require(String(data: encoded, encoding: .utf8))
    return ArtifactIsland(
      entry: entry, payloadJSON: json, colorScheme: scheme, id: id, openExternal: { opened.urls.append($0) })
  }

  // A page that no view hosts loads on the macOS host only: in the iOS simulator's unhosted test process the WebContent process
  // never becomes ready (the CI `snapshots` job timed out on every one of them). The island on iOS is covered by the
  // `proof-apple` screenshots (`-IrisArtifactSpike`); the policy, the scheme handler, the theme and the height cache are tested
  // on both.
  #if os(macOS)

    /// The whole package's tests share one process: the Prose benchmarks hold the main actor for about 90 s, and a page's first load
    /// (a cold WebContent process) waits behind them. A broken island fails the test long before this.
    private static let ceiling: Duration = .seconds(180)

    /// Polls `condition` every 50 ms until it holds or the ceiling passes.
    @discardableResult
    private func wait(
      _ what: String, sourceLocation: SourceLocation = #_sourceLocation, until condition: () async -> Bool
    ) async -> Bool {
      let deadline = ContinuousClock.now + Self.ceiling
      while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
      return false
    }

    private func script(_ island: ArtifactIsland, _ body: String) async -> Any? {
      try? await island.page.callJavaScript(body, contentWorld: .page)
    }

    private func text(_ island: ArtifactIsland, _ selector: String) async -> String? {
      await script(island, "return document.querySelector('\(selector)')?.textContent ?? null") as? String
    }

    private func loaded(_ island: ArtifactIsland, rendered selector: String = "#title") async -> Bool {
      guard
        await wait(
          "ready",
          until: {
            await island.refreshHeight(); return island.isReady && island.height > 20
          })
      else {
        return false
      }
      guard await wait("rendered \(selector)", until: { await text(island, selector) != nil }) else { return false }
      // The height follows the render by a re-measure or an observer callback, never in the same tick.
      return await wait(
        "the island to grow to its content",
        until: {
          await island.refreshHeight(); return island.height > 100
        })
    }

    @Test("The bundled page loads, measures itself and renders the payload")
    func rendersPayload() async throws {
      let island = try makeIsland()
      defer { island.teardown() }
      #expect(await loaded(island))
      #expect(await text(island, "#title") == "Latency by step")
      #expect(await script(island, "return document.querySelectorAll('.tile').length") as? Int == 3)
      #expect(island.page.url?.scheme == ArtifactSchemeHandler.scheme)
    }

    @Test("The CSP stops the page from fetching over the network")
    func networkBlocked() async throws {
      let island = try makeIsland()
      defer { island.teardown() }
      #expect(await loaded(island, rendered: "#net"))
      await wait("the fetch verdict") { await text(island, "#net") != "network: checking" }
      #expect(await text(island, "#net") == "network: blocked")
    }

    @Test("A script navigation to an https URL is refused and does not leave the island")
    func scriptNavigationRefused() async throws {
      let opened = Opened()
      let island = try makeIsland(opened: opened)
      defer { island.teardown() }
      #expect(await loaded(island))
      _ = await script(island, "location.href = 'https://example.com/'; return null")
      // A refusal is the absence of an event: give a navigation that would have happened time to start.
      try await Task.sleep(for: .seconds(1.5))
      #expect(island.page.url?.scheme == ArtifactSchemeHandler.scheme)
      #expect(opened.urls.isEmpty)
      #expect(await text(island, "#title") == "Latency by step")
    }

    @Test("A click on the button that navigates by script is refused too")
    func buttonNavigationRefused() async throws {
      let opened = Opened()
      let island = try makeIsland(opened: opened)
      defer { island.teardown() }
      #expect(await loaded(island))
      _ = await script(island, "document.getElementById('nav').click(); return null")
      try await Task.sleep(for: .seconds(1.5))
      #expect(island.page.url?.scheme == ArtifactSchemeHandler.scheme)
      #expect(opened.urls.isEmpty)
    }

    @Test("A followed link opens externally once and the page stays")
    func linkOpensExternally() async throws {
      let opened = Opened()
      let island = try makeIsland(opened: opened)
      defer { island.teardown() }
      #expect(await loaded(island))
      _ = await script(island, "document.getElementById('ext').click(); return null")
      await wait("openExternal") { !opened.urls.isEmpty }
      try await Task.sleep(for: .seconds(1))
      #expect(opened.urls == [URL(string: "https://example.com/docs")!])
      #expect(island.page.url?.scheme == ArtifactSchemeHandler.scheme)
    }

    @Test("The reported height follows the content up and down")
    func heightFollowsContent() async throws {
      let island = try makeIsland()
      defer { island.teardown() }
      #expect(await loaded(island))
      let base = island.height
      _ = await script(
        island,
        "const d = document.createElement('div'); d.id = 'tall'; d.style.height = '400px'; document.body.append(d); return null"
      )
      await wait("growth") {
        await island.refreshHeight(); return island.height >= base + 399
      }
      let grown = island.height
      _ = await script(island, "document.getElementById('tall').remove(); return null")
      await wait("shrink") {
        await island.refreshHeight(); return island.height <= grown - 399
      }
      #expect(abs(island.height - base) < 2)
    }

    @Test("More stat tiles make the island taller")
    func morePayloadMoreHeight() async throws {
      let island = try makeIsland()
      defer { island.teardown() }
      #expect(await loaded(island))
      let base = island.height
      let many = IslandSamplePayload(
        title: "Many",
        stats: (0..<12).map { IslandSamplePayload.Stat(name: "n\($0)", value: "\($0)", delta: "+0") },
        bars: [1, 2])
      let data = try JSONEncoder().encode(many)
      island.render(payloadJSON: try #require(String(data: data, encoding: .utf8)))
      await wait("taller") {
        await island.refreshHeight(); return island.height > base + 20
      }
      #expect(await text(island, "#title") == "Many")
    }

    @Test("A generated document loads, reports a height and its script does not run")
    func inlineDocument() async throws {
      let html = """
        <!doctype html><html><body><p id="r" style="color:red">x</p>\
        <script>document.getElementById('r').textContent = 'ran'</script></body></html>
        """
      let island = try makeIsland(.html(html), payload: Optional<String>.none)
      defer { island.teardown() }
      await wait("height") {
        await island.refreshHeight(); return island.isReady && island.height >= 1
      }
      #expect(await text(island, "#r") == "x")
      #expect(
        await script(island, "return getComputedStyle(document.getElementById('r')).color") as? String
          == "rgb(255, 0, 0)"
      )
      #expect(island.page.url?.absoluteString == "iris-artifact://doc/page")
    }

    @Test("The island of an HTML document refuses a network request: the document CSP blocks fetch and remote images")
    func htmlDocumentNetworkRefused() async throws {
      let asset = ArtifactAsset(
        ref: ReplyAssetRef(memoID: "m", assetID: "a"), kind: .doc, index: 0, format: .html, bytes: 0)
      let html = """
        <!doctype html><html><body><h1 id="t">Report</h1>\
        <img id="remote" src="https://example.com/pixel.png" alt=""></body></html>
        """
      let content = try #require(ArtifactContent(asset: asset, data: Data(html.utf8), scheme: .light))
      #expect(content.entry == .html(html))
      #expect(content.payloadJSON == nil)
      let island = ArtifactIsland(
        entry: content.entry, payloadJSON: "null", colorScheme: .light, openExternal: { _ in })
      defer { island.teardown() }
      await wait("the document") { await text(island, "#t") == "Report" }
      // The host's own script (not subject to the page CSP) asks the document's context to reach the network and records the
      // policy violations that context reports.
      let verdict =
        await script(
          island,
          """
          const violations = [];
          document.addEventListener('securitypolicyviolation', (event) => violations.push(event.effectiveDirective));
          let fetched;
          try { await fetch('https://example.com/data.json'); fetched = 'loaded'; } catch (error) { fetched = 'refused'; }
          await new Promise((resolve) => setTimeout(resolve, 300));
          return fetched + ' ' + violations.join(',');
          """) as? String
      #expect(verdict?.hasPrefix("refused ") == true, "verdict: \(verdict ?? "nil")")
      #expect(
        verdict?.contains("connect-src") == true || verdict?.contains("default-src") == true,
        "no CSP violation reported: \(verdict ?? "nil")")
      #expect(await script(island, "return document.getElementById('remote').naturalWidth") as? Int == 0)
    }

    @Test("The bundled renderer draws a show spec, and a spec it refuses is reported as refused")
    func rendererRefusal() async throws {
      let asset = ArtifactAsset(ref: ReplyAssetRef(memoID: "m", assetID: "s"), kind: .show, index: 0, bytes: 0)
      func island(_ spec: String) throws -> ArtifactIsland {
        let content = try #require(ArtifactContent(asset: asset, data: Data(spec.utf8), scheme: .light))
        return ArtifactIsland(
          entry: content.entry, payloadJSON: try #require(content.payloadJSON), colorScheme: .light,
          openExternal: { _ in })
      }
      let table = try island(#"{"type":"table","title":"Tasks","columns":["Task","Done"],"rows":[["Ship",true]]}"#)
      defer { table.teardown() }
      await wait("the table to render") { table.renderCount > 0 }
      #expect(!table.isRefused)
      #expect(await script(table, "return document.querySelectorAll('table').length") as? Int == 1)

      // Rows longer than the columns: valid JSON, a spec the renderer's validation refuses.
      let bad = try island(#"{"type":"table","columns":["A"],"rows":[["x","y"]]}"#)
      defer { bad.teardown() }
      await wait("the refusal") { bad.renderCount > 0 }
      #expect(bad.isRefused)
    }

    @Test("Switching to dark changes the theme variables")
    func schemeSwitch() async throws {
      let island = try makeIsland(scheme: .light)
      defer { island.teardown() }
      #expect(await loaded(island))
      let read = "return getComputedStyle(document.documentElement).getPropertyValue('--iris-bg').trim()"
      let light = await script(island, read) as? String
      #expect(light == ArtifactTheme.variables(for: .light)["--iris-bg"])
      island.setScheme(.dark)
      let dark = ArtifactTheme.variables(for: .dark)["--iris-bg"]
      await wait("dark variables") { await script(island, read) as? String == dark }
      #expect(light != dark)
    }

  #endif

  @Test("An island with a cached id starts at the cached height")
  func heightCache() throws {
    ArtifactHeightCache.store(321, for: "cache-test")
    defer { ArtifactHeightCache.removeAll() }
    let island = try makeIsland(id: "cache-test")
    defer { island.teardown() }
    #expect(island.height == 321)
  }

  @Test("The scheme handler serves bundled files, 404s the rest and always sends the CSP")
  func schemeHandler() {
    let found = ArtifactSchemeHandler.answer(for: URL(string: "iris-artifact://app/island.js"), document: nil)
    #expect(found.status == 200)
    #expect(found.headers["Content-Type"]?.hasPrefix("text/javascript") == true)
    #expect(found.headers["Content-Security-Policy"] == ArtifactSchemeHandler.bundledPolicy)
    #expect(found.headers["X-Content-Type-Options"] == "nosniff")
    for text in [
      "iris-artifact://app/missing.js", "iris-artifact://app/../Package.swift", "iris-artifact://app/a/b.js",
      "iris-artifact://doc/page", "iris-artifact://other/island.html", "https://example.com/island.html",
    ] {
      let answer = ArtifactSchemeHandler.answer(for: URL(string: text), document: nil)
      #expect(answer.status == 404, "\(text)")
      #expect(answer.headers["Content-Security-Policy"] != nil, "\(text)")
    }
    let doc = ArtifactSchemeHandler.answer(for: URL(string: "iris-artifact://doc/page"), document: "<p>x</p>")
    #expect(doc.status == 200)
    #expect(doc.headers["Content-Security-Policy"] == ArtifactSchemeHandler.documentPolicy)
    #expect(!ArtifactSchemeHandler.documentPolicy.contains("script-src"))
  }
}
