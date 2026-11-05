import Charts
import SwiftUI

/// One bar of the volume chart: a day or a week, with its memo count per series.
public struct VolumeBar: Identifiable, Equatable, Sendable {
  public var id: String
  /// The short axis label ("M", "W44").
  public var axisLabel: String
  /// The long name shown in the readout ("Mon 26", "W44 (partial)").
  public var name: String
  public var counts: [VolumeSeries: Int]

  public init(id: String, axisLabel: String, name: String, counts: [VolumeSeries: Int]) {
    self.id = id
    self.axisLabel = axisLabel
    self.name = name
    self.counts = counts
  }

  public var total: Int { counts.values.reduce(0, +) }
}

/// Memos per kind as stacked bars. Touching a bar selects it; the readout above the plot names it and shows its
/// counts (the latest bar until then). `names` are the localized series names, also used by the legend.
public struct VolumeChart: View {
  private let bars: [VolumeBar]
  private let series: [VolumeSeries]
  private let names: [VolumeSeries: String]
  private let summary: String
  @State private var selection: String?

  /// `series` is the ordered list to draw and name in the legend; a series no bar has a count for is left out of the legend.
  public init(bars: [VolumeBar], series: [VolumeSeries], names: [VolumeSeries: String], summary: String) {
    self.bars = bars
    self.series = series
    self.names = names
    self.summary = summary
  }

  private var shown: [VolumeSeries] {
    series.filter { series in bars.contains { $0.counts[series, default: 0] > 0 } }
  }

  private var selectedBar: VolumeBar? {
    bars.first { $0.id == selection } ?? bars.last
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      if let bar = selectedBar { readout(bar) }
      chart
      legend
    }
  }

  private var chart: some View {
    Chart {
      // The selected period sits on a faint band (`.sel` in `stats.html`) instead of dimming the others.
      if let selected = selectedBar {
        RectangleMark(x: .value("Period", selected.id), width: .ratio(0.94))
          .foregroundStyle(Theme.Ink.primary.opacity(0.06))
          .cornerRadius(6)
      }
      ForEach(bars) { bar in
        ForEach(series) { series in
          if let count = bar.counts[series], count > 0 {
            BarMark(x: .value("Period", bar.id), y: .value("Memos", count), width: .ratio(0.58))
              .foregroundStyle(by: .value("Kind", series.id))
          }
        }
      }
    }
    .chartForegroundStyleScale(
      domain: series.map(\.id), range: series.map(\.color)
    )
    .chartLegend(.hidden)
    // Every period keeps its slot, also the ones without a memo.
    .chartXScale(domain: bars.map(\.id))
    .chartXSelection(value: $selection)
    .chartXAxis {
      AxisMarks(values: bars.map(\.id)) { value in
        AxisValueLabel {
          if let id = value.as(String.self), let bar = bars.first(where: { $0.id == id }) {
            Text(verbatim: bar.axisLabel)
              .themeFont(.caption, weight: bar.id == selectedBar?.id ? .bold : .regular)
              .foregroundStyle(bar.id == selectedBar?.id ? Theme.Ink.primary : Theme.Ink.muted)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
        AxisGridLine().foregroundStyle(Theme.divider)
        AxisValueLabel().foregroundStyle(Theme.Ink.muted)
      }
    }
    .frame(height: 170)
    .accessibilityLabel(summary)
    .accessibilityIdentifier("stats.chart")
  }

  private func readout(_ bar: VolumeBar) -> some View {
    HStack(spacing: Theme.Spacing.md) {
      Text(verbatim: "\(bar.name) · \(bar.total)")
        .themeFont(.footnote, weight: .bold)
        .foregroundStyle(Theme.Ink.primary)
      ForEach(shown) { series in
        HStack(spacing: Theme.Spacing.xs) {
          RoundedRectangle(cornerRadius: 2).fill(series.color).frame(width: 8, height: 8)
          Text(verbatim: String(bar.counts[series, default: 0]))
            .themeFont(.caption)
            .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(names[series] ?? series.id) \(bar.counts[series, default: 0])"))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.md)
    .padding(.vertical, Theme.Spacing.sm)
    .background(Theme.Surface.subtle, in: .rect(cornerRadius: Theme.Radius.control))
    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.Surface.border, lineWidth: 0.5) }
  }

  private var legend: some View {
    ChipFlowLayout(spacing: Theme.Spacing.lg) {
      ForEach(shown) { series in
        HStack(spacing: Theme.Spacing.xs) {
          RoundedRectangle(cornerRadius: 3).fill(series.color).frame(width: 9, height: 9)
          Text(verbatim: names[series] ?? series.id)
            .themeFont(.caption, weight: .semibold)
            .foregroundStyle(Theme.Ink.secondary)
        }
      }
    }
    .accessibilityHidden(true)
  }
}
