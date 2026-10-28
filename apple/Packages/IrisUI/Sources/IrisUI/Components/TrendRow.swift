import Charts
import SwiftUI

/// One route's trend: its name, a sparkline over the periods, the total and the change against the period before.
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
    HStack(spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        RoundedRectangle(cornerRadius: 3).fill(series.color).frame(width: 9, height: 9)
        Text(verbatim: name)
          .themeFont(.subheadline, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)
      }
      .frame(width: 88, alignment: .leading)
      sparkline
      Text(verbatim: String(total))
        .themeFont(.subheadline, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
        .monospacedDigit()
        .frame(minWidth: 24, alignment: .trailing)
      Text(verbatim: changeText)
        .themeFont(.footnote)
        .foregroundStyle(changeColor)
        .monospacedDigit()
        .frame(minWidth: 56, alignment: .trailing)
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.sm + 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(name), \(total)"))
    .accessibilityValue(Text(verbatim: changeText))
  }

  private var sparkline: some View {
    Chart(Array(points.enumerated()), id: \.offset) { index, value in
      LineMark(x: .value("Period", index), y: .value("Memos", value))
        .foregroundStyle(series.color)
        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartYScale(domain: 0...Swift.max(points.max() ?? 1, 1))
    .frame(height: 26)
  }

  private var changeColor: Color {
    switch direction {
    case .up: Theme.Status.good
    case .down: Theme.Status.warn
    case .flat: Theme.Ink.muted
    }
  }
}
