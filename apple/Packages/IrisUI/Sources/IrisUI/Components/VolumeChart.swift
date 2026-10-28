import Charts
import SwiftUI

/// One bar of the volume chart: a day or a week, with its memo count per route series.
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

/// Memos per route as stacked bars. Touching a bar selects it; the readout above the plot names it and shows its
/// counts (the latest bar until then). `names` are the localized series names, also used by the legend.
public struct VolumeChart: View {
  private let bars: [VolumeBar]
  private let names: [VolumeSeries: String]
  private let summary: String
  @State private var selection: String?

  public init(bars: [VolumeBar], names: [VolumeSeries: String], summary: String) {
    self.bars = bars
    self.names = names
    self.summary = summary
  }

  private var shown: [VolumeSeries] {
    VolumeSeries.allCases.filter { series in bars.contains { $0.counts[series, default: 0] > 0 } }
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
      ForEach(bars) { bar in
        ForEach(VolumeSeries.allCases) { series in
          if let count = bar.counts[series], count > 0 {
            BarMark(x: .value("Period", bar.id), y: .value("Memos", count), width: .ratio(0.62))
              .foregroundStyle(by: .value("Route", series.rawValue))
              .opacity(selectedBar?.id == bar.id ? 1 : 0.55)
          }
        }
      }
    }
    .chartForegroundStyleScale(
      domain: VolumeSeries.allCases.map(\.rawValue), range: VolumeSeries.allCases.map(\.color)
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
        .accessibilityLabel(Text(verbatim: "\(names[series] ?? series.rawValue) \(bar.counts[series, default: 0])"))
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
          Text(verbatim: names[series] ?? series.rawValue)
            .themeFont(.caption, weight: .semibold)
            .foregroundStyle(Theme.Ink.secondary)
        }
      }
    }
    .accessibilityHidden(true)
  }
}
