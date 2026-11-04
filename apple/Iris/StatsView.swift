import IrisCore
import IrisUI
import SwiftUI

/// The Stats tab: memo volume per kind as bars over days or weeks, three headline tiles and a trend per kind.
struct StatsView: View {
  @Bindable var model: StatsModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
          content
        }
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.top, Theme.Spacing.sectionTop)
      }
      .accessibilityIdentifier("stats.view")
      // The Record accessory floats over the scroll's end: the last footnote stops above it.
      .contentMargins(.bottom, Theme.Spacing.gutter, for: .scrollContent)
      .takeBanner()
      .background(Theme.Surface.background)
      .toolbarVisibility(.hidden, for: .navigationBar)
      .statusBarScrim()
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
    VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
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
          StatTile(
            title: tile.title, value: tile.value, caption: tile.caption,
            captionColor: tile.isRise ? Theme.Status.good : Theme.Ink.muted)
        }
      }

      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
          Text("Memos per kind", comment: "Stats chart title")
            .themeFont(.subheadline, weight: .semibold)
            .foregroundStyle(Theme.Ink.primary)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: chartSubtitle)
            .themeFont(.caption)
            .foregroundStyle(Theme.Ink.muted)
        }
        VolumeChart(bars: report.bars, series: report.series, names: report.names, summary: summary(report))
      }
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.top, Theme.Spacing.inset)
      .padding(.bottom, Theme.Spacing.cozy)
      .detailCard()

      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(report.trends.enumerated()), id: \.element.id) { index, trend in
            if index > 0 { Divider().overlay(Theme.divider) }
            TrendRow(
              series: trend.series, name: report.names[trend.series] ?? "", points: trend.points,
              total: trend.total, changeText: trend.change, direction: trend.direction)
          }
        }
        .detailCard()
        Text(verbatim: trendsFootnote(report))
          .themeFont(.caption)
          .foregroundStyle(Theme.Ink.faint)
          .padding(.horizontal, Theme.Spacing.xs)
      }
    }
  }

  private var chartSubtitle: String {
    switch model.granularity {
    case .days: String(localized: "Stacked by kind, per day. Today is partial.", comment: "Stats chart subtitle")
    case .weeks:
      String(localized: "Stacked by kind, per week. The current week is partial.", comment: "Stats chart subtitle")
    }
  }

  private func trendsFootnote(_ report: StatsReport) -> String {
    switch model.granularity {
    case .days: String(localized: "Change against the 7 days before.", comment: "Stats trends footnote")
    case .weeks where report.bars.count > 1:
      String(localized: "Average per week over \(report.bars.count) weeks.", comment: "Stats trends footnote")
    case .weeks: String(localized: "Average per week.", comment: "Stats trends footnote, a single week")
    }
  }

  private func summary(_ report: StatsReport) -> String {
    String(localized: "Memos per kind. \(report.rangeText)", comment: "VoiceOver label of the volume chart")
  }
}
