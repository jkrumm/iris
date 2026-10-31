import Foundation
import SwiftUI

/// The kinds of the two widgets, shared so the app can name the one it reloads.
public enum IrisWidgetKind {
  public static let lastMemo = "com.jkrumm.iris.widgets.last-memo"
  public static let record = "com.jkrumm.iris.widgets.record-widget"
}

/// The families the Iris widgets draw. The extension maps WidgetKit's `WidgetFamily` onto this one, so the views have no
/// WidgetKit dependency and the snapshot tests can draw every family on the simulator.
public enum IrisWidgetFamily: Sendable, CaseIterable {
  case systemSmall, systemMedium, accessoryCircular, accessoryRectangular, accessoryInline

  /// Lock Screen families: always vibrant, no background.
  public var isAccessory: Bool {
    switch self {
    case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
    case .systemSmall, .systemMedium: false
    }
  }
}

/// WidgetKit's `WidgetRenderingMode`. `fullColor` keeps the basalt colors; `accented` (a tinted Home Screen) and `vibrant`
/// (the Lock Screen, StandBy at night) are drawn by the system from the alpha channel, so the views then use no state color
/// and mark what takes the accent with `widgetAccentable()`.
public enum IrisWidgetRendering: Sendable, CaseIterable {
  case fullColor, accented, vibrant
}

/// How a widget draws itself right now.
public struct IrisWidgetContext: Equatable, Sendable {
  public var family: IrisWidgetFamily
  public var rendering: IrisWidgetRendering
  /// `false` in StandBy and in a vibrant context: the system has taken the container background away.
  public var showsContainerBackground: Bool

  public init(
    family: IrisWidgetFamily, rendering: IrisWidgetRendering = .fullColor, showsContainerBackground: Bool = true
  ) {
    self.family = family
    self.rendering = rendering
    self.showsContainerBackground = showsContainerBackground
  }
}

/// How old the shown state is. The widget passes a date and the system keeps the text current ("3 min"); a snapshot test
/// passes a string, so the picture does not depend on the clock.
public enum WidgetAge: Equatable, Sendable {
  case since(Date)
  case text(String)
}

/// What the last-memo widget shows. Built from the stored snapshot, so every decision about missing, stale or settled
/// data is made here and unit tested.
public enum LastMemoWidgetContent: Equatable, Sendable {
  /// Nothing readable: no App Group (a Personal Team or unsigned build), no snapshot yet. The static "Open Iris" state.
  case noData
  /// The stored memo is an in-flight one nobody has updated for ``LastMemoSnapshot/staleAfter``: its state is unknown.
  case idle
  case memo(Line)

  public struct Line: Equatable, Sendable {
    public var phase: LastMemoSnapshot.Phase
    public var routeChip: String?
    public var headline: String?
    public var age: WidgetAge

    public init(phase: LastMemoSnapshot.Phase, routeChip: String?, headline: String?, age: WidgetAge) {
      self.phase = phase
      self.routeChip = routeChip
      self.headline = headline
      self.age = age
    }
  }

  public init(_ snapshot: LastMemoSnapshot?, at now: Date) {
    guard let snapshot else {
      self = .noData
      return
    }
    guard !snapshot.isStale(at: now) else {
      self = .idle
      return
    }
    self = .memo(
      Line(
        phase: snapshot.phase, routeChip: snapshot.routeChip, headline: snapshot.headline,
        age: .since(snapshot.updatedAt)))
  }
}

/// The strings the widgets show, in IrisUI's catalog (English source, German).
public enum IrisWidgetText {
  public static var lastMemoName: String {
    String(localized: "Last memo", bundle: #bundle, comment: "Widget gallery name of the last-memo widget")
  }
  public static var lastMemoDescription: String {
    String(
      localized: "The state of your newest memo.", bundle: #bundle,
      comment: "Widget gallery description of the last-memo widget")
  }
  public static var recordName: String {
    String(localized: "Record", bundle: #bundle, comment: "Widget gallery name of the record widget")
  }
  public static var recordDescription: String {
    String(
      localized: "Open Iris and start a voice memo.", bundle: #bundle,
      comment: "Widget gallery description of the record widget")
  }

  // The strings the views draw are `Text`, so they follow the environment's locale (the snapshot tests pin it).
  static var record: Text {
    Text("Record", bundle: #bundle, comment: "Widget record button caption")
  }
  static var recordLabel: Text {
    Text("Record a memo", bundle: #bundle, comment: "VoiceOver label of the widget's record button")
  }
  static var openIris: Text {
    Text("Open Iris", bundle: #bundle, comment: "Widget title when there is no memo data to show")
  }
  static var noDataHint: Text {
    Text(
      "Your latest memo shows here.", bundle: #bundle, comment: "Widget hint under Open Iris when there is no memo data"
    )
  }
  static var idleTitle: Text {
    Text("Ready", bundle: #bundle, comment: "Widget title when the last memo's state is unknown")
  }
  static var idleHint: Text {
    Text("Open Iris for your memos.", bundle: #bundle, comment: "Widget hint when the last memo's state is unknown")
  }

  static func title(_ phase: LastMemoSnapshot.Phase) -> Text {
    switch phase {
    case .processing: Text("Processing", bundle: #bundle, comment: "Widget memo state")
    case .needsRoute: Text("Needs a route", bundle: #bundle, comment: "Widget memo state")
    case .done: Text("Done", bundle: #bundle, comment: "Widget memo state")
    case .failed: Text("Failed", bundle: #bundle, comment: "Widget memo state")
    }
  }

  /// The line under the state for a memo that has no headline (the summary failed or has not arrived).
  static func hint(_ phase: LastMemoSnapshot.Phase) -> Text {
    switch phase {
    case .processing: Text("Iris is working on it", bundle: #bundle, comment: "Widget memo hint")
    case .needsRoute: Text("Where should this go?", bundle: #bundle, comment: "Widget memo hint")
    case .done: Text("Your memo is ready", bundle: #bundle, comment: "Widget memo hint")
    case .failed: Text("Iris could not finish this memo", bundle: #bundle, comment: "Widget memo hint")
    }
  }
}
