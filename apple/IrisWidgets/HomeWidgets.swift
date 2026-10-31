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
}

struct LastMemoProvider: TimelineProvider {
  private let store: any LastMemoSnapshotStoring = FileLastMemoSnapshotStore.appGroup()

  func placeholder(in context: Context) -> LastMemoEntry {
    LastMemoEntry(
      date: .now,
      content: .memo(.init(phase: .done, routeChip: nil, headline: "Wochenplan abgestimmt", age: .since(.now))),
      relevance: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (LastMemoEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : entry(at: .now))
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LastMemoEntry>) -> Void) {
    let now = Date.now
    let current = entry(at: now)
    // The app reloads the timeline on every change it sees. The only change nobody tells the widget about is an in-flight
    // state going stale, so that is the one date to wake up for; a settled state waits for the app.
    guard let snapshot = store.load(), !snapshot.phase.isSettled else {
      completion(Timeline(entries: [current], policy: .never))
      return
    }
    let staleAt = snapshot.updatedAt.addingTimeInterval(LastMemoSnapshot.staleAfter + 1)
    let idle = LastMemoEntry(date: max(staleAt, now), content: .idle, relevance: nil)
    completion(Timeline(entries: [current, idle], policy: .never))
  }

  private func entry(at date: Date) -> LastMemoEntry {
    let snapshot = store.load()
    return LastMemoEntry(
      date: date, content: LastMemoWidgetContent(snapshot, at: date), relevance: snapshot.flatMap(Self.relevance))
  }

  /// Smart Stack: a parked or failed memo asks for attention for an hour, a running or just-finished one for a while.
  /// (iPhone reads the entry's relevance; the provider-level `relevance()` is watchOS.)
  private static func relevance(_ snapshot: LastMemoSnapshot) -> TimelineEntryRelevance {
    switch snapshot.phase {
    case .needsRoute: TimelineEntryRelevance(score: 100, duration: 60 * 60)
    case .failed: TimelineEntryRelevance(score: 60, duration: 60 * 60)
    case .processing: TimelineEntryRelevance(score: 40, duration: 10 * 60)
    case .done: TimelineEntryRelevance(score: 20, duration: 15 * 60)
    }
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
