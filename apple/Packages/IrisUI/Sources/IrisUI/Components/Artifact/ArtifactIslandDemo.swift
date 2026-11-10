import SwiftUI

/// What the bundled `island.html` renders: a title, stat tiles and bars.
struct IslandSamplePayload: Encodable, Sendable {
  struct Stat: Encodable, Sendable {
    let name: String
    let value: String
    let delta: String
  }

  let title: String
  let stats: [Stat]
  let bars: [Double]

  static let sample = IslandSamplePayload(
    // l10n:ignore sample data
    title: "Latency by step",
    stats: [
      Stat(name: "Transcribe", value: "1.8 s", delta: "-0.2"),
      Stat(name: "Act", value: "6.4 s", delta: "+0.9"),
      Stat(name: "Notify", value: "0.3 s", delta: "0.0"),
    ],
    bars: [1.8, 6.4, 0.3, 2.2, 4.1, 3.0])
}

/// A conversation with artifact islands between the bubbles. Debug and proof screens only (`-IrisArtifactSpike`): the screenshot
/// shows the measured height under each island.
public struct ArtifactIslandDemo: View {
  private let islands: Int
  @State private var heights: [Int: CGFloat] = [:]

  public init(islands: Int = 1) {
    self.islands = max(1, islands)
  }

  public var body: some View {
    ScrollView {
      // A plain VStack, not lazy: every island is alive at once, which is what the memory measurement counts.
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        ChatBubble(side: .user, time: "09:41") {
          Text(verbatim: "How long does each step of the pipeline take?")
            .themeFont(.subheadline)
            .foregroundStyle(Theme.Ink.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(0..<islands, id: \.self) { index in
          VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
            ArtifactWebView(
              entry: .bundled("island.html"), payload: IslandSamplePayload.sample, id: "demo-\(index)",
              onHeight: { heights[index] = $0 })
            Text(verbatim: "island height \(Int(heights[index] ?? 0)) pt")
              .themeFont(.caption)
              .foregroundStyle(Theme.Ink.faint)
          }
        }
        ChatBubble(side: .assistant, time: "09:42") {
          Text(verbatim: "Act dominates; the rest is quick.")
            .themeFont(.subheadline)
            .foregroundStyle(Theme.Ink.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, Theme.Spacing.screenMargin)
      .padding(.vertical, Theme.Spacing.lg)
    }
    .background(Theme.Surface.background)
  }
}
