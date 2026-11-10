import Foundation
import Observation
import SwiftUI
import WebKit
import os

/// Heights of islands seen before, by caller id, so a lazy stack that recycles an island starts at the size it had.
@MainActor
enum ArtifactHeightCache {
  private static var heights: [String: CGFloat] = [:]

  static func height(for id: String) -> CGFloat? { heights[id] }
  static func store(_ height: CGFloat, for id: String) { heights[id] = height }
  static func removeAll() { heights.removeAll() }
}

/// Decides every navigation of the island's page through `ArtifactNavigationPolicy`.
/// A navigation without a target frame is a new window (`target=_blank`): it counts as the main frame, so a link opens externally.
struct ArtifactNavigationDecider: WebPage.NavigationDeciding {
  let openExternal: @MainActor (URL) -> Void

  @MainActor
  mutating func decidePolicy(
    for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
  ) async -> WKNavigationActionPolicy {
    let decision = ArtifactNavigationPolicy.decide(
      url: action.request.url, isLinkActivation: action.navigationType == .linkActivated,
      island: ArtifactSchemeHandler.scheme, isMainFrame: action.target?.isMainFrame ?? true)
    switch decision {
    case .allow:
      return .allow
    case .cancel:
      return .cancel
    case .openExternally(let url):
      openExternal(url)
      return .cancel
    }
  }
}

/// The script-message handler the user content controller retains. It holds the island weakly, so the controller (which the
/// page's configuration keeps alive) never keeps the island alive.
@MainActor
final class ArtifactBridgeHandler: NSObject, WKScriptMessageHandler {
  static let name = "iris"
  weak var island: ArtifactIsland?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "height":
      guard let value = (body["value"] as? NSNumber)?.doubleValue else { return }
      island?.bridgeReportedHeight(CGFloat(value))
    case "ready":
      island?.bridgeReady()
    default:
      return
    }
  }
}

/// One sandboxed WebView: a page that sizes itself, takes its colors from the Theme and loads without a network.
///
/// The page is served from `iris-artifact://` (bundle or memory) under a CSP, navigation is filtered, and a bridge script in an
/// isolated content world (`iris-bridge`, invisible to page scripts) applies the theme variables, measures the document and posts
/// `height` / `ready` to the message handler `iris`. The page's own `window.iris.render(payload)` receives the data.
@MainActor
@Observable
final class ArtifactIsland {
  /// The height before the page has measured itself and none is cached.
  static let placeholderHeight: CGFloat = 120
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "artifact")
  private static let bridgeWorld = WKContentWorld.world(name: "iris-bridge")

  @ObservationIgnored let page: WebPage
  let entry: ArtifactEntry
  /// The measured height of the document; drives the view's frame.
  private(set) var height: CGFloat
  /// The bridge has measured the document once: the page is up and `render` has been called.
  private(set) var isReady = false
  private(set) var failure: String?
  /// The height SwiftUI's scroll geometry reports for the web view's content. Diagnostic only.
  var scrollContentHeight: CGFloat = 0
  private(set) var payloadJSON: String

  @ObservationIgnored private var scheme: ColorScheme
  @ObservationIgnored private let id: String?
  @ObservationIgnored private let controller: WKUserContentController
  @ObservationIgnored private let handler = ArtifactBridgeHandler()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private let start = ContinuousClock.now
  @ObservationIgnored private var isTornDown = false

  /// - Parameters:
  ///   - scrollable: The document may scroll (the full-screen island); inline islands size to their content instead.
  ///   - id: Keys the process-wide height cache.
  init(
    entry: ArtifactEntry, payloadJSON: String, colorScheme: ColorScheme, id: String? = nil, scrollable: Bool = false,
    openExternal: @escaping @MainActor (URL) -> Void
  ) {
    self.entry = entry
    self.payloadJSON = payloadJSON
    self.scheme = colorScheme
    self.id = id
    height = id.flatMap { ArtifactHeightCache.height(for: $0) } ?? Self.placeholderHeight

    let controller = WKUserContentController()
    self.controller = controller
    var configuration = WebPage.Configuration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.upgradeKnownHostsToHTTPS = false
    configuration.userContentController = controller
    let document: String? =
      if case .html(let html) = entry { html } else { nil }
    var failure: String?
    if let urlScheme = URLScheme(ArtifactSchemeHandler.scheme) {
      configuration.urlSchemeHandlers[urlScheme] = ArtifactSchemeHandler(document: document)
    } else {
      failure = "scheme \(ArtifactSchemeHandler.scheme) rejected"
    }
    page = WebPage(
      configuration: configuration, navigationDecider: ArtifactNavigationDecider(openExternal: openExternal))
    #if DEBUG
      page.isInspectable = true
    #else
      page.isInspectable = false
    #endif

    handler.island = self
    controller.add(handler, contentWorld: Self.bridgeWorld, name: ArtifactBridgeHandler.name)
    controller.addUserScript(
      WKUserScript(
        source: Self.bridgeScript(variables: ArtifactTheme.json(for: colorScheme), scrollable: scrollable),
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.bridgeWorld))

    if failure == nil, let url = ArtifactSchemeHandler.url(for: entry) {
      load(url)
    } else {
      failure = failure ?? "no URL for \(entry)"
    }
    self.failure = failure
  }

  isolated deinit {
    teardown()
  }

  /// Stops loading and releases the controller's hold on the handler. Safe to call twice.
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    loadTask?.cancel()
    controller.removeScriptMessageHandler(forName: ArtifactBridgeHandler.name, contentWorld: Self.bridgeWorld)
    controller.removeAllUserScripts()
    handler.island = nil
  }

  // MARK: Payload and theme

  /// Hands the page new data (`window.iris.render`). Generated documents have no script, so this is a no-op for them.
  func render(_ payload: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else {
      failure = "payload not encodable"
      return
    }
    render(payloadJSON: json)
  }

  func render(payloadJSON json: String) {
    payloadJSON = json
    guard isReady else { return }
    pushPayload()
  }

  /// Re-applies the theme variables for `scheme`.
  func setScheme(_ scheme: ColorScheme) {
    self.scheme = scheme
    guard !isTornDown else { return }
    Task { [page] in
      _ = try? await page.callJavaScript(
        "window.__irisApply(variables)", arguments: ["variables": ArtifactTheme.variables(for: scheme)],
        contentWorld: Self.bridgeWorld)
    }
  }

  /// Asks the page for its current height. The observers push it on their own; this is the fallback for a throttled page.
  func refreshHeight() async {
    guard !isTornDown else { return }
    let result = try? await page.callJavaScript(
      "return window.__irisMeasure ? window.__irisMeasure() : null", contentWorld: Self.bridgeWorld)
    guard let value = (result as? NSNumber)?.doubleValue else { return }
    Self.logger.notice("refresh height \(value, privacy: .public) at \(self.elapsed, privacy: .public)")
    bridgeReportedHeight(CGFloat(value))
    // A page that answered is up even if its animation frames are throttled (an occluded Mac window) and `ready` never came.
    bridgeReady()
  }

  // MARK: Bridge callbacks

  fileprivate func bridgeReportedHeight(_ value: CGFloat) {
    Self.logger.notice("height \(value, privacy: .public) at \(self.elapsed, privacy: .public)")
    guard value >= 1, abs(value - height) >= 1 else { return }
    height = value
    if let id { ArtifactHeightCache.store(value, for: id) }
  }

  fileprivate func bridgeReady() {
    Self.logger.notice("ready at \(self.elapsed, privacy: .public)")
    guard !isReady else { return }
    isReady = true
    setScheme(scheme)
    pushPayload()
  }

  // MARK: Private

  private var elapsed: String {
    (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds], width: .narrow))
  }

  private func load(_ url: URL) {
    loadTask = Task { [weak self, page] in
      do {
        for try await _ in page.load(url) {}
      } catch {
        self?.failure = String(describing: error)
        return
      }
      await self?.refreshHeight()
    }
  }

  private func pushPayload() {
    guard case .bundled = entry, !isTornDown else { return }
    Task { [page, payloadJSON] in
      _ = try? await page.callJavaScript(
        "if (window.iris) window.iris.render(JSON.parse(payload))", arguments: ["payload": payloadJSON],
        contentWorld: .page)
      // The page changed under the observers: measure it now, in case no rendering update comes to tell them.
      await self.refreshHeight()
    }
  }

  /// Runs in the isolated `iris-bridge` world at document start. `window.__irisApply` and `window.__irisMeasure` live in that world
  /// only. Everything it sets is inline style through the CSSOM, which a CSP does not block.
  private static func bridgeScript(variables: String, scrollable: Bool) -> String {
    """
    (() => {
      const root = document.documentElement;
      const apply = (vars) => { for (const key in vars) root.style.setProperty(key, vars[key]); };
      apply(\(variables));
      window.__irisApply = apply;
      const measure = () => Math.ceil(root.getBoundingClientRect().height);
      window.__irisMeasure = measure;
      const post = (message) => window.webkit.messageHandlers.\(ArtifactBridgeHandler.name).postMessage(message);
      let last = -1;
      let queued = false;
      const report = () => {
        queued = false;
        const value = measure();
        if (Math.abs(value - last) < 1) return;
        const first = last < 0;
        last = value;
        post({ type: "height", value });
        if (first) post({ type: "ready" });
      };
      // An occluded Mac window gets no rendering updates, so neither animation frames nor ResizeObserver callbacks fire there:
      // a timer reports too (measuring forces layout), whichever comes first.
      const schedule = () => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(report);
        setTimeout(report, 120);
      };
      document.addEventListener("DOMContentLoaded", () => {
        root.style.setProperty("height", "auto");
        root.style.setProperty("overflow", "\(scrollable ? "auto" : "hidden")");
        document.body.style.setProperty("height", "auto");
        document.body.style.setProperty("overflow", "\(scrollable ? "visible" : "hidden")");
        const observer = new ResizeObserver(schedule);
        observer.observe(root);
        observer.observe(document.body);
        schedule();
      });
    })();
    """
  }
}
