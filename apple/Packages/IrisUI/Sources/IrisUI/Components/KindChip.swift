import SwiftUI

/// A capsule chip naming what Hermes made of a memo (its free-form kind, for example Answer or Github issue).
/// Glass is limited to the chip itself; the content stays flat.
public struct KindChip: View {
  private let label: String
  private let systemImage: String

  public init(label: String, systemImage: String = "tag.fill") {
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
        localized: "Kind: \(label)",
        bundle: #bundle,
        comment: "VoiceOver label of the memo kind chip. The placeholder is Hermes' free-form kind label (data)."))
  }
}
