import CoreGraphics
import SwiftUI

/// An artifact fence of a reply, inline. A show spec is one island at its content height; a document is a titled card (title,
/// format, size) that opens the viewer. A fence the server stored nothing for is code; a file that fails to load or that the
/// renderer refuses is code with a retry.
struct ArtifactBlockView: View {
  let kind: ArtifactBlock.Kind
  let source: String
  let asset: ArtifactAsset?
  let textRole: Theme.TextRole

  var body: some View {
    if let asset {
      switch kind {
      case .show: ShowArtifactCard(asset: asset, source: source, textRole: textRole)
      case .doc: DocumentArtifactCard(asset: asset, source: source)
      }
    } else {
      MarkdownBlockView(text: source, textRole: textRole)
    }
  }
}

/// A show spec inline: a live island while it is on screen and within the conversation's budget, else the snapshot it left.
private struct ShowArtifactCard: View {
  let asset: ArtifactAsset
  let source: String
  let textRole: Theme.TextRole
  @Environment(\.artifactStore) private var store
  @Environment(\.artifactIslandBudget) private var budget
  @Environment(\.colorScheme) private var colorScheme
  @State private var isRefused = false

  private var islandID: String { "\(asset.ref.memoID)/\(asset.ref.assetID)" }
  private var snapshotID: String { "\(islandID)/\(colorScheme == .dark ? "dark" : "light")" }

  var body: some View {
    content
      .task(id: asset.ref) { await store?.load(asset.ref) }
  }

  @ViewBuilder private var content: some View {
    switch store?.phase(for: asset.ref) ?? .failed {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity)
        .frame(height: ArtifactHeightCache.height(for: islandID) ?? ArtifactIsland.placeholderHeight)
    case .failed:
      ArtifactFallbackView(source: source, textRole: textRole) { retry() }
    case .loaded(let data):
      if !isRefused, let artifact = ArtifactContent(asset: asset, data: data, scheme: colorScheme) {
        island(artifact)
      } else {
        ArtifactFallbackView(source: source, textRole: textRole) { retry() }
      }
    }
  }

  private func island(_ artifact: ArtifactContent) -> some View {
    Group {
      if budget?.isLive(islandID) ?? true {
        ArtifactWebView(
          entry: artifact.entry, payloadJSON: artifact.payloadJSON ?? "null", id: islandID, allowsFullscreen: false,
          onRefused: { isRefused = true },
          onSnapshot: { [snapshotID] image in budget?.store(image, for: snapshotID) })
      } else {
        standIn
      }
    }
    .overlay(alignment: .topTrailing) {
      ArtifactOpenButton(request: ArtifactViewerRequest(asset: asset, source: source))
    }
    // Appearing counts as shown (a host without a scroll view never reports scroll visibility); the scroll view corrects it.
    .onAppear { budget?.setVisible(islandID, true) }
    .onScrollVisibilityChange(threshold: 0.01) { budget?.setVisible(islandID, $0) }
    .onDisappear { budget?.setVisible(islandID, false) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("artifact.card.show")
  }

  /// The snapshot of the island at its last height, or an empty frame of that height until there is one.
  @ViewBuilder private var standIn: some View {
    let height = ArtifactHeightCache.height(for: islandID) ?? ArtifactIsland.placeholderHeight
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
    if let image = budget?.snapshot(for: snapshotID) {
      Image(decorative: image, scale: 1)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: height, alignment: .top)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.Surface.border, lineWidth: 0.5) }
        .accessibilityIdentifier("artifact.snapshot")
    } else {
      shape.strokeBorder(Theme.Surface.border, lineWidth: 0.5)
        .frame(height: height)
    }
  }

  private func retry() {
    isRefused = false
    Task { await store?.retry(asset.ref) }
  }
}

/// A document inline: its title, format and size; a tap opens the viewer.
private struct DocumentArtifactCard: View {
  let asset: ArtifactAsset
  let source: String
  @State private var presented: ArtifactViewerRequest?
  @Environment(\.openArtifact) private var openArtifact

  var body: some View {
    Button {
      let request = ArtifactViewerRequest(asset: asset, source: source)
      if let openArtifact { openArtifact(request) } else { presented = request }
    } label: {
      HStack(spacing: Theme.Spacing.md) {
        Image(systemName: asset.format == .html ? "chevron.left.forwardslash.chevron.right" : "doc.richtext")
          .themeFont(.body)
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityHidden(true)
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
          .lineLimit(2)
          Text(verbatim: ArtifactLabels.detail(for: asset))
            .themeFont(.caption)
            .foregroundStyle(Theme.Ink.muted)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .themeFont(.caption)
          .foregroundStyle(Theme.Ink.faint)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.cardInsetVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .detailCard()
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint(Text("Opens the document", bundle: #bundle, comment: "VoiceOver hint of a document card"))
    .accessibilityIdentifier("artifact.card.doc")
    .modifier(ArtifactViewerPresentation(presented: $presented))
  }
}

enum ArtifactLabels {
  /// "Markdown · 1 KB": the format's name (never localized) and the file size.
  static func detail(for asset: ArtifactAsset) -> String {
    let format =
      switch (asset.kind, asset.format) {
      case (.show, _): "JSON"
      case (.doc, .html): "HTML"
      case (.doc, _): "Markdown"
      }
    return "\(format) · \(Int64(asset.bytes).formatted(.byteCount(style: .file)))"
  }
}

/// The corner button of an inline island: opens the artifact in the viewer.
private struct ArtifactOpenButton: View {
  let request: ArtifactViewerRequest
  @State private var presented: ArtifactViewerRequest?
  @Environment(\.openArtifact) private var openArtifact

  var body: some View {
    Button {
      if let openArtifact { openArtifact(request) } else { presented = request }
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
      Text("Show full screen", bundle: #bundle, comment: "Button on an inline artifact: opens it full screen")
    )
    .accessibilityIdentifier("artifact.open")
    .modifier(ArtifactViewerPresentation(presented: $presented))
  }
}

/// The fence as code, with a retry under it: a file that did not load or that the renderer refused.
struct ArtifactFallbackView: View {
  let source: String
  let textRole: Theme.TextRole
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      MarkdownBlockView(text: source, textRole: textRole)
      Button(action: retry) {
        Label {
          Text("Could not show this. Tap to retry.", bundle: #bundle, comment: "Under an artifact shown as code")
        } icon: {
          Image(systemName: "arrow.clockwise")
        }
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.muted)
        .frame(minHeight: Theme.Spacing.tapTarget, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("artifact.retry")
    }
  }
}

/// Presents the viewer over the screen: full screen on iOS, a sheet on the Mac when no window opener is set.
struct ArtifactViewerPresentation: ViewModifier {
  @Binding var presented: ArtifactViewerRequest?
  @Environment(\.artifactStore) private var store

  func body(content: Content) -> some View {
    #if os(iOS)
      content.fullScreenCover(item: $presented) { request in
        ArtifactViewer(request: request).environment(\.artifactStore, store)
      }
    #else
      content.sheet(item: $presented) { request in
        ArtifactViewer(request: request).environment(\.artifactStore, store)
      }
    #endif
  }
}

extension ArtifactViewerRequest: Identifiable {
  public var id: String { "\(asset.ref.memoID)/\(asset.ref.assetID)" }
}
