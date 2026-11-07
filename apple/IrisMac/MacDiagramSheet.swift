import CoreGraphics
import IrisUI
import SwiftUI

/// A diagram of a reply, larger: the image scaled to fit a sheet, a Close button, Escape closes it too.
struct MacDiagramSheet: View {
  let image: CGImage
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: Theme.Spacing.md) {
      Image(decorative: image, scale: 2)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Diagram", comment: "Accessibility label of a rendered Mermaid diagram"))
        .accessibilityAddTraits(.isImage)
      Button(String(localized: "Close", comment: "Closes the full diagram view"), action: onClose)
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("mac.diagram.close")
    }
    .padding(Theme.Spacing.lg)
    .frame(width: Theme.Spacing.macSheetWidth, height: Theme.Spacing.macSheetHeight)
    .background(Theme.Surface.background)
    .accessibilityIdentifier("mac.diagram")
  }
}

/// The diagram the conversation shows in ``MacDiagramSheet``; `Identifiable` so a sheet can present it.
struct MacZoomedDiagram: Identifiable {
  let id = UUID()
  let image: CGImage
}
