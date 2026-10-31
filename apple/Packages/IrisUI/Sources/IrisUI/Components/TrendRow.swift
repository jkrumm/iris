import SwiftUI

/// One route's trend: its name, a sparkline over the periods, the total and the change against the period before. Laid out as
/// the `.trow` grid of `docs/design/mockups/stats.html`: name 78 pt, the sparkline takes the rest, total and change right-aligned.
public struct TrendRow: View {
  public enum Direction: Sendable { case up, down, flat }

  private let series: VolumeSeries
  private let name: String
  private let points: [Int]
  private let total: Int
  private let changeText: String
  private let direction: Direction

  public init(
    series: VolumeSeries, name: String, points: [Int], total: Int, changeText: String, direction: Direction
  ) {
    self.series = series
    self.name = name
    self.points = points
    self.total = total
    self.changeText = changeText
    self.direction = direction
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.cozy) {
      HStack(spacing: Theme.Spacing.sm) {
        RoundedRectangle(cornerRadius: 3).fill(series.color).frame(width: 9, height: 9)
        Text(verbatim: name)
          .themeFont(.subheadline, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)
      }
      .frame(width: 78, alignment: .leading)
      sparkline
      Text(verbatim: String(total))
        .themeFont(.subheadline, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .monospacedDigit()
        .frame(minWidth: 22, alignment: .trailing)
      Text(verbatim: changeText)
        .themeFont(.footnote)
        .foregroundStyle(changeColor)
        .monospacedDigit()
        .frame(minWidth: 64, alignment: .trailing)
    }
    .padding(.horizontal, Theme.Spacing.inset)
    .padding(.vertical, Theme.Spacing.sm + 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(name), \(total)"))
    .accessibilityValue(Text(verbatim: changeText))
  }

  private var sparkline: some View {
    Sparkline(points: points)
      .stroke(series.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      .frame(height: 26)
      .accessibilityHidden(true)
  }

  private var changeColor: Color {
    switch direction {
    case .up: Theme.Status.good
    case .down: Theme.Status.warn
    case .flat: Theme.Ink.muted
    }
  }
}

/// The mockup's polyline: straight segments between the periods, scaled to the series' own maximum, inset 5 pt from the top
/// and 3 pt from the bottom of its 26 pt box so a zero and a peak both keep their whole stroke (`spark()` in `stats.html`).
struct Sparkline: Shape {
  let points: [Int]

  /// The y of a value in a box `height` tall: the mockup's `h - 3 - (v / max) * (h - 8)`.
  static func y(of value: Int, maximum: Int, height: CGFloat) -> CGFloat {
    height - 3 - CGFloat(value) / CGFloat(Swift.max(maximum, 1)) * (height - 8)
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard !points.isEmpty else { return path }
    let maximum = points.max() ?? 1
    let spots = points.enumerated().map { index, value in
      CGPoint(
        x: points.count > 1 ? rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1) : rect.midX,
        y: rect.minY + Self.y(of: value, maximum: maximum, height: rect.height))
    }
    if spots.count == 1 {
      // A single period has no line to draw: a dot, so the row is not blank.
      path.addEllipse(in: CGRect(x: spots[0].x - 1, y: spots[0].y - 1, width: 2, height: 2))
    } else {
      path.addLines(spots)
    }
    return path
  }
}
