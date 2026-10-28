import CoreGraphics
import SwiftUI

/// The full view of a diagram: pinch to zoom, drag to pan once zoomed, double-tap to toggle between fit and 2.5x, share
/// from the toolbar. It is a pure view over one image; the app presents it full screen.
public struct ZoomableImageView: View {
  private let image: CGImage
  private let title: String
  private let onClose: () -> Void

  @State private var scale: CGFloat = 1
  @State private var settledScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var settledOffset: CGSize = .zero

  private static let doubleTapScale: CGFloat = 2.5
  private static let maxScale: CGFloat = 6

  public init(image: CGImage, title: String, onClose: @escaping () -> Void) {
    self.image = image
    self.title = title
    self.onClose = onClose
  }

  public var body: some View {
    NavigationStack {
      Image(decorative: image, scale: 2)
        .resizable()
        .scaledToFit()
        .padding(Theme.Spacing.lg)
        .scaleEffect(scale)
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.background)
        .contentShape(.rect)
        .gesture(pinch)
        .simultaneousGesture(pan)
        .onTapGesture(count: 2, perform: toggleZoom)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("thread.diagram.zoom")
        .navigationTitle(title)
        .navigationBarTitleDisplayModeInline()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(
              String(localized: "Close", bundle: #bundle, comment: "Closes the full diagram view"),
              systemImage: "xmark", action: onClose
            )
            .accessibilityIdentifier("thread.diagram.close")
          }
          ToolbarItem(placement: .primaryAction) {
            ShareLink(
              item: Image(decorative: image, scale: 2),
              preview: SharePreview(title, image: Image(decorative: image, scale: 2))
            )
            .accessibilityIdentifier("thread.diagram.share")
          }
        }
    }
  }

  private var pinch: some Gesture {
    MagnifyGesture()
      .onChanged { value in
        scale = min(max(settledScale * value.magnification, 1), Self.maxScale)
      }
      .onEnded { _ in
        settledScale = scale
        if scale <= 1 { reset() }
      }
  }

  private var pan: some Gesture {
    DragGesture()
      .onChanged { value in
        guard scale > 1 else { return }
        offset = CGSize(
          width: settledOffset.width + value.translation.width,
          height: settledOffset.height + value.translation.height)
      }
      .onEnded { _ in settledOffset = offset }
  }

  private func toggleZoom() {
    withAnimation(.snappy) {
      if scale > 1 {
        reset()
      } else {
        scale = Self.doubleTapScale
        settledScale = scale
      }
    }
  }

  private func reset() {
    scale = 1
    settledScale = 1
    offset = .zero
    settledOffset = .zero
  }
}

extension View {
  /// `navigationBarTitleDisplayMode(.inline)` where it exists; the macOS host of the package tests has no such mode.
  @ViewBuilder fileprivate func navigationBarTitleDisplayModeInline() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}
