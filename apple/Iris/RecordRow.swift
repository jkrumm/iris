import IrisCore
import IrisUI
import SwiftUI

/// The record control in the tab bar's bottom accessory: three visible buttons, no hidden gesture, all the same capsule
/// height. Hermes is the one primary (the default: a take whose memo goes to Hermes, `Accent.fill`); Transcribe (a take that
/// only becomes a transcript) and Text (opens the composer) are the same capsule in a tinted secondary fill, so no button reads
/// as a tab. The accessory is a capsule in two placements: `expanded` has room for icon and title on every button, `inline`
/// (the tab bar is minimized) keeps the title on Hermes only and the other two are icon-only capsules.
struct RecordRow: View {
  let model: TakeModel
  let onCompose: () -> Void
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  /// The secondary buttons' fill: the accent at the strength of the user's chat bubble (`ChatBubble`), a shape without a second primary.
  private static let secondaryFillOpacity = 0.14

  private var showsSecondaryTitles: Bool { placement != .inline }

  var body: some View {
    HStack(spacing: Theme.Spacing.barGap) {
      Button {
        Task { await model.start(mode: .hermes) }
      } label: {
        Label("Hermes", systemImage: MemoMode.hermes.recordIcon)
          .labelStyle(RecordLabelStyle(showsTitle: true))
          .recordCapsule(foreground: Theme.Accent.onFill, fill: Theme.Accent.fill, fillsWidth: true)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Hermes")
      .accessibilityHint("Starts a voice memo for Hermes.")
      .accessibilityIdentifier("record.start")

      Button {
        Task { await model.start(mode: .transcribe) }
      } label: {
        Label("Transcribe", systemImage: MemoMode.transcribe.recordIcon)
          .labelStyle(RecordLabelStyle(showsTitle: showsSecondaryTitles))
          .recordCapsule(foreground: Theme.Accent.tint, fill: Theme.Accent.tint.opacity(Self.secondaryFillOpacity))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Transcribe")
      .accessibilityHint("Starts a voice memo that is only transcribed.")
      .accessibilityIdentifier("record.transcribe")

      Button(action: onCompose) {
        Label("Text", systemImage: "keyboard")
          .labelStyle(RecordLabelStyle(showsTitle: showsSecondaryTitles))
          .recordCapsule(foreground: Theme.Accent.tint, fill: Theme.Accent.tint.opacity(Self.secondaryFillOpacity))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Text")
      .accessibilityHint("Opens the composer to type a memo.")
      .accessibilityIdentifier("record.text")
    }
    .themeFont(.subheadline, weight: .semibold)
    .padding(.horizontal, Theme.Spacing.snug)
    .disabled(!model.canStart)
  }
}

extension View {
  /// One record button: a capsule at the tap-target height (a circle when icon-only), so the three buttons differ in fill only.
  fileprivate func recordCapsule<Fill: ShapeStyle>(foreground: Color, fill: Fill, fillsWidth: Bool = false) -> some View
  {
    self
      .foregroundStyle(foreground)
      .frame(
        minWidth: Theme.Spacing.tapTarget, maxWidth: fillsWidth ? .infinity : nil, minHeight: Theme.Spacing.tapTarget
      )
      .background(fill, in: .capsule)
      .contentShape(.capsule)
  }
}

/// Icon and title side by side; the title drops out in the inline accessory (the button keeps its accessibility label).
private struct RecordLabelStyle: LabelStyle {
  let showsTitle: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Spacing.snug) {
      configuration.icon
      if showsTitle { configuration.title.lineLimit(1) }
    }
    // The title keeps its natural width ("Transkribieren" must not wrap); the Hermes button gives way.
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, Theme.Spacing.cozy)
  }
}

extension MemoMode {
  /// The name of the mode on the record row, the take screen and the banner.
  var recordTitle: String {
    switch self {
    case .hermes: String(localized: "Hermes", comment: "Memo mode")
    case .transcribe: String(localized: "Transcribe", comment: "Memo mode")
    }
  }

  /// The SF Symbols of the SDK (Xcode 27.1) have no robot glyph, so `sparkles` stands for Hermes; no two modes share a glyph.
  var recordIcon: String {
    switch self {
    case .hermes: "sparkles"
    case .transcribe: "text.alignleft"
    }
  }
}
