import SwiftUI

/// The words of the live preview as the take screen shows them, localized by the caller.
public struct LiveTranscriptText: Sendable, Equatable {
  /// What the recognizer has settled on. Primary ink.
  public var finalized: String
  /// What it is still changing. Secondary ink: it may read differently a moment later.
  public var volatile: String

  public init(finalized: String, volatile: String) {
    self.finalized = finalized
    self.volatile = volatile
  }
}

/// The on-device transcript of the take as it is spoken (round 2, R5): settled text in primary ink, still-changing text in
/// secondary ink, the newest line always in view. Display only; the server's transcript is the truth.
public struct LiveTranscript: View {
  /// Lines the region keeps in view at the default text size.
  static let lines = 4

  private let text: LiveTranscriptText

  public init(_ text: LiveTranscriptText) {
    self.text = text
  }

  public var body: some View {
    ScrollView {
      transcript
        .themeFont(.body)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
    .defaultScrollAnchor(.bottom)
    .frame(height: height)
    .mask(fade)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      String(
        localized: "Live transcript", bundle: #bundle,
        comment: "VoiceOver name of the take screen's live transcript, the words shown as they are spoken")
    )
    .accessibilityValue(spoken)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityIdentifier("take.preview")
  }

  /// Settled text then volatile text, one flowing paragraph (a space between the two only when both exist).
  private var transcript: Text {
    let settled = Text(verbatim: text.finalized).foregroundStyle(Theme.Ink.primary)
    guard !text.volatile.isEmpty else { return settled }
    let separator = text.finalized.isEmpty ? "" : " "
    return settled + Text(verbatim: separator + text.volatile).foregroundStyle(Theme.Ink.muted)
  }

  private var spoken: String {
    [text.finalized, text.volatile].filter { !$0.isEmpty }.joined(separator: " ")
  }

  @ScaledMetric(relativeTo: .body) private var lineHeight = 24

  private var height: CGFloat { lineHeight * CGFloat(Self.lines) }

  /// The oldest line fades out at the top instead of being cut.
  private var fade: some View {
    LinearGradient(
      stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)], startPoint: .top,
      endPoint: .bottom)
  }
}
