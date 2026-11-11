import Foundation
import SwiftUI
import WebKit

/// An artifact (chart, stat tiles, a generated document) in a sandboxed web view that sizes itself to its content. Scrolling is off,
/// so touches fall through to the surrounding scroll view; a corner button opens the same content full screen.
public struct ArtifactWebView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  private let entry: ArtifactEntry
  private let payloadJSON: String
  private let id: String?
  private let allowsFullscreen: Bool
  private let openExternal: ((URL) -> Void)?
  private let onHeight: ((CGFloat) -> Void)?
  private let onRefused: (() -> Void)?
  private let onSnapshot: ((CGImage) -> Void)?

  /// Created on first appearance, not in `init`: SwiftUI builds a view value on every parent update and a web page is not cheap.
  @State private var island: ArtifactIsland?
  @State private var isFullscreen = false

  /// - Parameters:
  ///   - payloadJSON: The JSON the page's `window.iris.render` receives.
  ///   - id: Keys the height cache, so a lazy stack that recycles the view does not make it jump.
  ///   - openExternal: Where a tapped link goes; the system opens it when `nil`.
  ///   - onHeight: Called with the measured height whenever it changes.
  ///   - onRefused: Called when the page could not load or its renderer refused the payload (it shows its notice).
  ///   - onSnapshot: Called with an image of the content once a payload has rendered, for a stand-in when the view is gone.
  public init(
    entry: ArtifactEntry, payloadJSON: String = "null", id: String? = nil, allowsFullscreen: Bool = true,
    openExternal: ((URL) -> Void)? = nil, onHeight: ((CGFloat) -> Void)? = nil, onRefused: (() -> Void)? = nil,
    onSnapshot: ((CGImage) -> Void)? = nil
  ) {
    self.entry = entry
    self.payloadJSON = payloadJSON
    self.id = id
    self.allowsFullscreen = allowsFullscreen
    self.openExternal = openExternal
    self.onHeight = onHeight
    self.onRefused = onRefused
    self.onSnapshot = onSnapshot
  }

  public init(
    entry: ArtifactEntry, payload: some Encodable, id: String? = nil, allowsFullscreen: Bool = true,
    openExternal: ((URL) -> Void)? = nil, onHeight: ((CGFloat) -> Void)? = nil
  ) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    self.init(
      entry: entry, payloadJSON: json, id: id, allowsFullscreen: allowsFullscreen, openExternal: openExternal,
      onHeight: onHeight)
  }

  public var body: some View {
    Group {
      if let island {
        ArtifactIslandView(island: island, fixedHeight: true)
          .overlay(alignment: .topTrailing) { if allowsFullscreen { fullscreenButton } }
          .onChange(of: island.height) { _, height in onHeight?(height) }
          .onChange(of: colorScheme) { _, scheme in island.setScheme(scheme) }
          .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await island.refreshHeight() }
          }
          .onChange(of: payloadJSON) { _, json in island.render(payloadJSON: json) }
          .onChange(of: island.failure) { _, failure in if failure != nil { onRefused?() } }
          .onChange(of: island.renderCount) { rendered(island) }
          .modifier(
            ArtifactFullscreenPresentation(isPresented: $isFullscreen) {
              ArtifactFullscreenView(
                entry: entry, payloadJSON: payloadJSON, openExternal: externalOpener,
                dismiss: { isFullscreen = false })
            })
      } else {
        Color.clear.frame(
          height: id.flatMap { ArtifactHeightCache.height(for: $0) } ?? ArtifactIsland.placeholderHeight)
      }
    }
    .onAppear { createIslandIfNeeded() }
  }

  /// A payload has rendered: report a refusal, or take the snapshot once the canvas has painted (a chart draws on the next frame).
  private func rendered(_ island: ArtifactIsland) {
    if island.isRefused {
      onRefused?()
      return
    }
    guard let onSnapshot else { return }
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      if let image = await island.snapshot() { onSnapshot(image) }
    }
  }

  private var fullscreenButton: some View {
    Button {
      isFullscreen = true
    } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.Ink.muted)
        .padding(Theme.Spacing.snug)
        .background(Theme.Surface.panel.opacity(0.85), in: Circle())
    }
    .buttonStyle(.plain)
    .padding(Theme.Spacing.snug)
    .accessibilityLabel(
      Text("Show full screen", bundle: #bundle, comment: "Button on an inline artifact: opens it full screen"))
  }

  /// Captures the environment's action and the caller's closure, never `self`: the island outlives a body and `self` owns the island.
  private var externalOpener: @MainActor (URL) -> Void {
    let custom = openExternal
    let system = openURL
    return { url in
      if let custom {
        custom(url)
      } else {
        system(url)
      }
    }
  }

  private func createIslandIfNeeded() {
    guard island == nil else { return }
    let created = ArtifactIsland(
      entry: entry, payloadJSON: payloadJSON, colorScheme: colorScheme, id: id, openExternal: externalOpener)
    island = created
    onHeight?(created.height)
  }
}

/// The web view of one island with the island chrome: transparent, no gestures of its own, rounded with a hairline.
struct ArtifactIslandView: View {
  let island: ArtifactIsland
  /// Inline islands take the measured height; the full-screen one fills what it is given and scrolls.
  let fixedHeight: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
    WebView(island.page)
      .webViewContentBackground(.hidden)
      .webViewBackForwardNavigationGestures(.disabled)
      .webViewMagnificationGestures(.disabled)
      .webViewLinkPreviews(.disabled)
      .webViewOnScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, height in
        island.scrollContentHeight = height
      }
      .scrollDisabled(fixedHeight)
      .frame(height: fixedHeight ? island.height : nil)
      .clipShape(shape)
      .overlay { shape.strokeBorder(Theme.Surface.border, lineWidth: 0.5).allowsHitTesting(false) }
  }
}

private struct ArtifactFullscreenView: View {
  @Environment(\.colorScheme) private var colorScheme
  /// Created on appearance, like the inline island; a web page cannot sit in two web views, so this is a second model.
  @State private var island: ArtifactIsland?
  let entry: ArtifactEntry
  let payloadJSON: String
  let openExternal: @MainActor (URL) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: Theme.Spacing.md) {
      HStack {
        Spacer()
        Button(action: dismiss) {
          Text("Close", bundle: #bundle, comment: "Closes the full-screen artifact")
        }
        .buttonStyle(.glass)
      }
      if let island {
        ArtifactIslandView(island: island, fixedHeight: false)
          .onChange(of: colorScheme) { _, scheme in island.setScheme(scheme) }
      } else {
        Spacer()
      }
    }
    .padding(Theme.Spacing.md)
    #if os(macOS)
      .frame(minWidth: 640, minHeight: 480)
    #endif
    .background(Theme.Surface.background)
    .onAppear {
      guard island == nil else { return }
      island = ArtifactIsland(
        entry: entry, payloadJSON: payloadJSON, colorScheme: colorScheme, scrollable: true, openExternal: openExternal)
    }
  }
}

/// Full screen on iOS, a large sheet on the Mac.
private struct ArtifactFullscreenPresentation<Presented: View>: ViewModifier {
  @Binding var isPresented: Bool
  @ViewBuilder let presented: () -> Presented

  func body(content: Content) -> some View {
    #if os(iOS)
      content.fullScreenCover(isPresented: $isPresented, content: presented)
    #else
      content.sheet(isPresented: $isPresented, content: presented)
    #endif
  }
}
