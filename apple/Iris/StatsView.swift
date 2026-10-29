import IrisCore
import IrisUI
import SwiftUI

/// The Stats tab: memo volume per route as bars over days or weeks, three headline tiles and a trend per route.
struct StatsView: View {
  @Bindable var model: StatsModel

  var body: some View {
    NavigationStack {
      ScrollView {
        content
          .padding(.horizontal, Theme.Spacing.lg)
          .padding(.vertical, Theme.Spacing.md)
      }
      .accessibilityIdentifier("stats.view")
      .takeBanner()
      .background(Theme.Surface.background)
      .navigationTitle(String(localized: "Stats", comment: "Navigation title of the Stats tab"))
      .refreshable { await model.load() }
      .task { await model.load() }
    }
  }

  @ViewBuilder private var content: some View {
    if let report = model.report {
      if report.isEmpty {
        ContentUnavailableView(
          String(localized: "No memos yet", comment: "Stats empty title"), systemImage: "chart.bar",
          description: Text("Memos in the last eight weeks show up here.", comment: "Stats empty description")
        )
        .accessibilityIdentifier("stats.empty")
      } else {
        loaded(report)
      }
    } else if model.loadFailed {
      ContentUnavailableView {
        Label(
          String(localized: "Could not load stats", comment: "Stats error title"),
          systemImage: "exclamationmark.triangle")
      } actions: {
        Button(String(localized: "Try again", comment: "Retries the stats load")) { Task { await model.load() } }
      }
      .accessibilityIdentifier("stats.error")
    } else {
      ProgressView().frame(maxWidth: .infinity, minHeight: 240)
    }
  }

  private func loaded(_ report: StatsReport) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
      Picker(String(localized: "Period", comment: "Stats granularity picker"), selection: $model.granularity) {
        Text("Days", comment: "Stats granularity").tag(StatsReport.Granularity.days)
        Text("Weeks", comment: "Stats granularity").tag(StatsReport.Granularity.weeks)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("stats.picker")

      Text(verbatim: report.rangeText)
        .themeFont(.footnote)
        .foregroundStyle(Theme.Ink.muted)

      HStack(spacing: Theme.Spacing.sm) {
        ForEach(report.tiles, id: \.title) { tile in
          StatTile(title: tile.title, value: tile.value, caption: tile.caption)
        }
      }

      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        DetailSectionLabel(String(localized: "Memos per route", comment: "Stats chart title"))
        VolumeChart(bars: report.bars, names: Self.seriesNames, summary: summary(report))
      }
      .padding(Theme.Spacing.lg)
      .detailCard()

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(report.trends.enumerated()), id: \.element.id) { index, trend in
          if index > 0 { Divider().overlay(Theme.divider) }
          TrendRow(
            series: trend.series, name: Self.seriesNames[trend.series] ?? "", points: trend.points,
            total: trend.total, changeText: trend.change, direction: trend.direction)
        }
      }
      .detailCard()
    }
  }

  private func summary(_ report: StatsReport) -> String {
    String(localized: "Memos per route. \(report.rangeText)", comment: "VoiceOver label of the volume chart")
  }

  static var seriesNames: [VolumeSeries: String] {
    [
      .hermes: String(localized: "Hermes", comment: "Route name"),
      .journal: String(localized: "Journal", comment: "Route name"),
      .tabs: String(localized: "Tabs", comment: "Route name"),
      .unrouted: String(localized: "Unrouted", comment: "Stats series for memos without a route"),
    ]
  }
}
