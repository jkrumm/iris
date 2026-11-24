import IrisCore
import IrisUI
import SwiftUI

/// The record control in the tab bar's bottom accessory: three visible buttons, no hidden gesture, all the same height. They are
/// rounded rectangles with a gap between them, not capsules that fill the accessory edge to edge, so none reads as a tab segment.
/// Hermes is the one primary (the default: a take whose memo goes to Hermes, `Accent.fill`, takes the room the others leave);
/// Transcribe (a take that only becomes a transcript) and Text (opens the composer) are outlined in the accent on a faint tint:
/// actions, not a second primary. The accessory is in two placements: `expanded` has room for icon and title on every button,
/// `inline` (the tab bar is minimized) keeps the title on Hermes only and the other two are icon-only squares.
struct RecordRow: View {
  let model: TakeModel
  let onCompose: () -> Void
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  /// The secondary buttons' faint fill and their outline: the accent, so they are buttons without being a second primary.
  private static let secondaryFillOpacity = 0.08
  private static let secondaryOutlineOpacity = 0.5

  private var showsSecondaryTitles: Bool { placement != .inline }

  var body: some View {
    HStack(spacing: Theme.Spacing.barGap) {
      Button {
        Task { await model.start(mode: .hermes) }
      } label: {
        Label("Hermes", systemImage: MemoMode.hermes.recordIcon)
          .labelStyle(RecordLabelStyle(showsTitle: true))
          .recordButton(foreground: Theme.Accent.onFill, fill: Theme.Accent.fill, outline: nil, fillsWidth: true)
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
          .recordButton(
            foreground: Theme.Accent.tint, fill: Theme.Accent.tint.opacity(Self.secondaryFillOpacity),
            outline: Theme.Accent.tint.opacity(Self.secondaryOutlineOpacity))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Transcribe")
      .accessibilityHint("Starts a voice memo that is only transcribed.")
      .accessibilityIdentifier("record.transcribe")

      Button(action: onCompose) {
        Label("Text", systemImage: "keyboard")
          .labelStyle(RecordLabelStyle(showsTitle: showsSecondaryTitles))
          .recordButton(
            foreground: Theme.Accent.tint, fill: Theme.Accent.tint.opacity(Self.secondaryFillOpacity),
            outline: Theme.Accent.tint.opacity(Self.secondaryOutlineOpacity))
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
  /// One record button: a rounded rectangle at the tap-target height (a square when icon-only); the secondaries add an outline.
  fileprivate func recordButton(foreground: Color, fill: some ShapeStyle, outline: Color?, fillsWidth: Bool = false)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
    return
      self
      .foregroundStyle(foreground)
      .frame(
        minWidth: Theme.Spacing.tapTarget, maxWidth: fillsWidth ? .infinity : nil, minHeight: Theme.Spacing.tapTarget
      )
      .background(fill, in: shape)
      .overlay { if let outline { shape.strokeBorder(outline, lineWidth: 1) } }
      .contentShape(shape)
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
