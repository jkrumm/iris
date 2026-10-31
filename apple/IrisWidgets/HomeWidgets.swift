import AppIntents
import IrisUI
import SwiftUI
import WidgetKit

// The Home Screen / Lock Screen widgets. They read one small file the app writes into the App Group container
// (`LastMemoSnapshot`) and touch nothing else: no network, no Keychain token, no `APIClient` (the extension still links
// `IrisCore` for the Live Activity's attributes, but nothing here names it). Without the App Group (a Personal Team or an
// unsigned simulator build) the store is unavailable and both widgets draw their static state.

extension WidgetFamily {
  fileprivate var irisFamily: IrisWidgetFamily {
    switch self {
    case .systemSmall: .systemSmall
    case .systemMedium: .systemMedium
    case .accessoryCircular: .accessoryCircular
    case .accessoryRectangular: .accessoryRectangular
    case .accessoryInline: .accessoryInline
    // Families the widgets do not declare; the system never asks for them.
    default: .systemSmall
    }
  }
}

extension WidgetRenderingMode {
  fileprivate var irisRendering: IrisWidgetRendering {
    switch self {
    case .fullColor: .fullColor
    case .accented: .accented
    default: .vibrant
    }
  }
}

/// The record action: the control's own `OpenRecorderIntent`, so a widget press takes the same road (unlock, open the app,
/// start the take in the foreground). Whether `Button(intent:)` of an `OpenIntent` brings the app forward from a widget the
/// way a control does is checked on the device (`docs/spikes/device-checklist.md`).
private func recordButton(_ label: AnyView) -> some View {
  Button(intent: OpenRecorderIntent()) { label }
    .buttonStyle(.plain)
}

/// Reads the environment WidgetKit sets and hands the views plain values.
private struct IrisWidgetContextReader<Content: View>: View {
  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var rendering
  @Environment(\.showsWidgetContainerBackground) private var showsBackground
  let content: (IrisWidgetContext) -> Content

  var body: some View {
    content(
      IrisWidgetContext(
        family: family.irisFamily, rendering: rendering.irisRendering, showsContainerBackground: showsBackground))
  }
}

// MARK: Last memo

struct LastMemoEntry: TimelineEntry {
  let date: Date
  let content: LastMemoWidgetContent
  let relevance: TimelineEntryRelevance?

  init(_ entry: LastMemoTimelinePlan.Entry) {
    date = entry.date
    content = entry.content
    relevance = entry.relevance.map { TimelineEntryRelevance(score: $0.score, duration: $0.duration) }
  }

  init(date: Date, content: LastMemoWidgetContent) {
    self.date = date
    self.content = content
    relevance = nil
  }
}

struct LastMemoProvider: TimelineProvider {
  private let store: any LastMemoSnapshotStoring = FileLastMemoSnapshotStore.appGroup()

  func placeholder(in context: Context) -> LastMemoEntry {
    LastMemoEntry(
      date: .now,
      content: .memo(.init(phase: .done, routeChip: nil, headline: "Wochenplan abgestimmt", age: .since(.now))))
  }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (LastMemoEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : LastMemoEntry(plan(at: .now).entries[0]))
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LastMemoEntry>) -> Void) {
    // `.never`: the app reloads on every change; the plan's idle entry covers the one change nobody announces.
    completion(Timeline(entries: plan(at: .now).entries.map(LastMemoEntry.init), policy: .never))
  }

  private func plan(at now: Date) -> LastMemoTimelinePlan {
    LastMemoTimelinePlan(snapshot: store.load(), now: now)
  }
}

struct LastMemoWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: IrisWidgetKind.lastMemo, provider: LastMemoProvider()) { entry in
      IrisWidgetContextReader { context in
        LastMemoWidgetView(content: entry.content, context: context, action: recordButton)
      }
      .containerBackground(Theme.Surface.panel, for: .widget)
    }
    .configurationDisplayName(IrisWidgetText.lastMemoName)
    .description(IrisWidgetText.lastMemoDescription)
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

// MARK: Record

struct RecordEntry: TimelineEntry {
  let date: Date
}

struct RecordProvider: TimelineProvider {
  func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: .now) }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (RecordEntry) -> Void) {
    completion(RecordEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RecordEntry>) -> Void) {
    completion(Timeline(entries: [RecordEntry(date: .now)], policy: .never))
  }
}

struct RecordWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: IrisWidgetKind.record, provider: RecordProvider()) { _ in
      IrisWidgetContextReader { context in
        RecordWidgetView(context: context, action: recordButton)
      }
      .containerBackground(Theme.Surface.panel, for: .widget)
    }
    .configurationDisplayName(IrisWidgetText.recordName)
    .description(IrisWidgetText.recordDescription)
    .supportedFamilies([.systemSmall, .accessoryCircular])
  }
}
