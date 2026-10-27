import SwiftUI

/// A capsule chip naming the active audio route (for example the built-in microphone or AirPods).
/// Glass is limited to the chip itself; the content stays flat.
public struct RouteChip: View {
  private let label: String
  private let systemImage: String

  public init(label: String, systemImage: String = "mic.fill") {
    self.label = label
    self.systemImage = systemImage
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.xs) {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
      Text(verbatim: label)
        .lineLimit(1)
    }
    .themeFont(.footnote, weight: .medium)
    .foregroundStyle(Theme.Ink.primary)
    .padding(.horizontal, Theme.Spacing.md)
    .padding(.vertical, Theme.Spacing.sm)
    .glassEffect(.regular, in: .capsule)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      String(
        localized: "Audio route: \(label)",
        bundle: #bundle,
        comment: "VoiceOver label of the route chip. The placeholder is the input device name."))
  }
}
