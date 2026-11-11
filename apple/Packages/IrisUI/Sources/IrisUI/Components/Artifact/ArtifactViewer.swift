import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// One artifact on its own: full screen on iOS, a window on the Mac. The same island as inline, scrollable, with Share (the raw
/// spec or document as a file) and Copy (its text). A file that fails to load or that the renderer refuses is its fence as code
/// with a retry.
public struct ArtifactViewer: View {
  private let request: ArtifactViewerRequest
  @Environment(\.artifactStore) private var store
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var isRefused = false
  @State private var shareFile: URL?
  @State private var copied = false

  public init(request: ArtifactViewerRequest) {
    self.request = request
  }

  private var asset: ArtifactAsset { request.asset }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      header
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .padding(Theme.Spacing.md)
    #if os(macOS)
      .frame(minWidth: 640, minHeight: 480)
    #endif
    .background(Theme.Surface.background)
    .task(id: asset.ref) { await store?.load(asset.ref) }
    .task(id: loadedData) {
      guard let loadedData else { return }
      shareFile = try? ArtifactExport.file(for: asset, data: loadedData)
    }
    .accessibilityIdentifier("artifact.viewer")
  }

  private var phase: ArtifactStore.Phase { store?.phase(for: asset.ref) ?? .failed }

  private var loadedData: Data? {
    if case .loaded(let data) = phase { data } else { nil }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.cozy) {
      VStack(alignment: .leading, spacing: Theme.Spacing.rowLineGap) {
        Group {
          if let title = asset.title {
            Text(verbatim: title)
          } else {
            Text("Document", bundle: #bundle, comment: "Title of an untitled document artifact in a reply")
          }
        }
        .themeFont(.subheadline)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)
        Text(verbatim: ArtifactLabels.detail(for: asset))
          .themeFont(.caption)
          .foregroundStyle(Theme.Ink.muted)
      }
      Spacer(minLength: 0)
      Button(action: copy) {
        Label {
          if copied {
            Text("Copied", bundle: #bundle, comment: "The artifact viewer's Copy button after a copy")
          } else {
            Text("Copy", bundle: #bundle, comment: "Copies an artifact's text in the artifact viewer")
          }
        } icon: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
      }
      .disabled(loadedData == nil)
      .accessibilityIdentifier("artifact.viewer.copy")
      if let shareFile {
        ShareLink(item: shareFile) {
          Label {
            Text("Share", bundle: #bundle, comment: "Shares an artifact's file from the artifact viewer")
          } icon: {
            Image(systemName: "square.and.arrow.up")
          }
        }
        .accessibilityIdentifier("artifact.viewer.share")
      }
      #if os(iOS)
        Button {
          dismiss()
        } label: {
          Text("Close", bundle: #bundle, comment: "Closes the full-screen artifact")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("artifact.viewer.close")
      #endif
    }
    .labelStyle(.iconOnly)
    .themeFont(.body)
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed:
      ScrollView { ArtifactFallbackView(source: request.source, textRole: .callout, retry: retry) }
    case .loaded(let data):
      if !isRefused, let artifact = ArtifactContent(asset: asset, data: data, scheme: colorScheme) {
        ArtifactViewerPage(artifact: artifact) { isRefused = true }
      } else {
        ScrollView { ArtifactFallbackView(source: request.source, textRole: .callout, retry: retry) }
      }
    }
  }

  private func retry() {
    isRefused = false
    Task { await store?.retry(asset.ref) }
  }

  private func copy() {
    guard let loadedData, let text = String(data: loadedData, encoding: .utf8) else { return }
    #if os(iOS)
      UIPasteboard.general.string = text
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }
}

/// The viewer's island: the whole document, scrolling inside the web view.
private struct ArtifactViewerPage: View {
  let artifact: ArtifactContent
  let onRefused: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openURL) private var openURL
  /// Created on appearance, like the inline island; a web page cannot sit in two web views, so this is a model of its own.
  @State private var island: ArtifactIsland?

  var body: some View {
    Group {
      if let island {
        ArtifactIslandView(island: island, fixedHeight: false)
          .onChange(of: colorScheme) { _, scheme in island.setScheme(scheme) }
          .onChange(of: artifact.payloadJSON) { _, json in if let json { island.render(payloadJSON: json) } }
          .onChange(of: island.failure) { _, failure in if failure != nil { onRefused() } }
          .onChange(of: island.renderCount) { if island.isRefused { onRefused() } }
      } else {
        Color.clear
      }
    }
    .onAppear {
      guard island == nil else { return }
      let open = openURL
      island = ArtifactIsland(
        entry: artifact.entry, payloadJSON: artifact.payloadJSON ?? "null", colorScheme: colorScheme, scrollable: true,
        openExternal: { open($0) })
    }
  }
}
