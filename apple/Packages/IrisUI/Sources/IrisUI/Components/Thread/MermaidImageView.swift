import CoreGraphics
import SwiftUI

/// A rendered Mermaid diagram of a reply for the current appearance. Tapping opens it in the zoomable full view
/// through `onOpen`. While the PNG loads the card holds the diagram's aspect ratio, so nothing jumps.
public struct MermaidImageView: View {
  private let asset: MermaidAsset
  private let onOpen: (CGImage) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.replyImageStore) private var store

  public init(asset: MermaidAsset, onOpen: @escaping (CGImage) -> Void) {
    self.asset = asset
    self.onOpen = onOpen
  }

  public var body: some View {
    let ref = asset.ref(for: colorScheme)
    content(for: ref)
      .frame(maxWidth: .infinity)
      .padding(Theme.Spacing.md)
      .detailCard()
      .task(id: ref) { await store?.load(ref) }
  }

  @ViewBuilder private func content(for ref: ReplyAssetRef) -> some View {
    switch store?.phase(for: ref) ?? .failed {
    case .loaded(let image):
      Button {
        onOpen(image)
      } label: {
        Image(decorative: image, scale: 2)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: CGFloat(asset.width))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Diagram", bundle: #bundle, comment: "VoiceOver label of a rendered Mermaid diagram"))
      .accessibilityHint(Text("Opens the diagram full screen", bundle: #bundle, comment: "VoiceOver hint"))
      .accessibilityIdentifier("thread.diagram")
    case .loading:
      placeholder { ProgressView() }
    case .failed:
      placeholder {
        Button {
          Task { await store?.load(ref) }
        } label: {
          Label {
            Text("Diagram unavailable. Tap to retry.", bundle: #bundle, comment: "Shown when a diagram image failed")
          } icon: {
            Image(systemName: "arrow.clockwise")
          }
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    Color.clear
      .aspectRatio(asset.aspectRatio, contentMode: .fit)
      .frame(maxWidth: CGFloat(asset.width))
      .overlay { content() }
  }
}
