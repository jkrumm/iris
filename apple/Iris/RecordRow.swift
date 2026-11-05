import IrisCore
import IrisUI
import SwiftUI

/// The record control in the tab bar's bottom accessory: three visible buttons, no hidden gesture. A large Hermes button
/// (the default: a take whose memo goes to Hermes), a smaller Transcribe button (a take that only becomes a transcript) and a
/// smaller Text button (opens the composer). The accessory is a capsule in two placements: `expanded` has room for icon and
/// title on every button, `inline` (the tab bar is minimized) keeps the title on Hermes only.
struct RecordRow: View {
  let model: TakeModel
  let onCompose: () -> Void
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  private var showsSecondaryTitles: Bool { placement != .inline }

  var body: some View {
    HStack(spacing: Theme.Spacing.barGap) {
      Button {
        Task { await model.start(mode: .hermes) }
      } label: {
        Label("Hermes", systemImage: MemoMode.hermes.recordIcon)
          .labelStyle(RecordLabelStyle(showsTitle: true))
          .foregroundStyle(Theme.Accent.onFill)
          .frame(maxWidth: .infinity, minHeight: Theme.Spacing.tapTarget)
          .background(Theme.Accent.fill, in: .capsule)
          .contentShape(.capsule)
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
          .foregroundStyle(Theme.Accent.tint)
          .frame(minHeight: Theme.Spacing.tapTarget)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Transcribe")
      .accessibilityHint("Starts a voice memo that is only transcribed.")
      .accessibilityIdentifier("record.transcribe")

      Button(action: onCompose) {
        Label("Text", systemImage: "keyboard")
          .labelStyle(RecordLabelStyle(showsTitle: showsSecondaryTitles))
          .foregroundStyle(Theme.Accent.tint)
          .frame(minHeight: Theme.Spacing.tapTarget)
          .contentShape(.rect)
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
