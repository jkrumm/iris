import SwiftUI
import WidgetKit

/// Slot for the record action. IrisUI cannot name the app's `OpenRecorderIntent`, so the widget wraps the label in
/// `Button(intent: OpenRecorderIntent())`; a snapshot test passes the label through.
public typealias WidgetRecordAction<Action: View> = (AnyView) -> Action

extension ActivityPhase {
  fileprivate init(_ phase: LastMemoSnapshot.Phase) {
    switch phase {
    case .processing: self = .processing
    case .needsRoute: self = .needsRoute
    case .done: self = .done
    case .failed: self = .failed
    }
  }
}

extension IrisWidgetContext {
  fileprivate var isFullColor: Bool { rendering == .fullColor }

  fileprivate func tint(_ phase: LastMemoSnapshot.Phase) -> Color {
    guard isFullColor else { return .primary }
    switch phase {
    case .processing: return Theme.Accent.tint
    case .needsRoute: return Theme.Status.warn
    case .done: return Theme.Status.good
    case .failed: return Theme.Status.bad
    }
  }

  fileprivate var primaryInk: Color { isFullColor ? Theme.Ink.primary : .primary }
  fileprivate var secondaryInk: Color { isFullColor ? Theme.Ink.secondary : .secondary }
}

// MARK: Record

/// The record button's face: a filled accent circle on the Home Screen, a translucent one where the system recolors.
struct WidgetRecordGlyph: View {
  let context: IrisWidgetContext
  let diameter: CGFloat

  var body: some View {
    Image(systemName: "mic.fill")
      .font(.system(size: diameter * 0.42, weight: .semibold))
      .foregroundStyle(context.isFullColor ? Theme.Accent.onFill : Color.primary)
      .frame(width: diameter, height: diameter)
      .background(
        Circle().fill(context.isFullColor ? Theme.Accent.fill : Color.primary.opacity(0.22))
      )
      .widgetAccentable()
      .accessibilityHidden(true)
  }
}

/// The record widget: a big microphone that opens Iris and starts a take (`systemSmall`, which StandBy shows too, and the
/// Lock Screen circle).
public struct RecordWidgetView<Action: View>: View {
  private let context: IrisWidgetContext
  private let action: WidgetRecordAction<Action>

  public init(context: IrisWidgetContext, action: @escaping WidgetRecordAction<Action>) {
    self.context = context
    self.action = action
  }

  public var body: some View {
    action(AnyView(face))
      .accessibilityLabel(IrisWidgetText.recordLabel)
  }

  @ViewBuilder private var face: some View {
    switch context.family {
    case .accessoryCircular:
      ZStack {
        Circle().fill(Color.primary.opacity(0.22))
        Image(systemName: "mic.fill")
          .font(.system(size: 26, weight: .semibold))
          .widgetAccentable()
      }
    default:
      VStack(spacing: Theme.Spacing.cozy) {
        WidgetRecordGlyph(context: context, diameter: 72)
        IrisWidgetText.record
          .themeFont(.callout, weight: .semibold)
          .foregroundStyle(context.primaryInk)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(.rect)
    }
  }
}

// MARK: Last memo

/// The last-memo widget in every family: the state of the newest memo and its headline; the medium Home Screen widget also
/// carries a record button.
public struct LastMemoWidgetView<Action: View>: View {
  private let content: LastMemoWidgetContent
  private let context: IrisWidgetContext
  private let action: WidgetRecordAction<Action>

  public init(
    content: LastMemoWidgetContent, context: IrisWidgetContext, action: @escaping WidgetRecordAction<Action>
  ) {
    self.content = content
    self.context = context
    self.action = action
  }

  public var body: some View {
    switch context.family {
    case .systemSmall: text(headlineLines: 4, large: true)
    case .systemMedium:
      HStack(alignment: .center, spacing: Theme.Spacing.lg) {
        text(headlineLines: 4, large: true)
        action(AnyView(WidgetRecordGlyph(context: context, diameter: 56)))
          .accessibilityLabel(IrisWidgetText.recordLabel)
      }
    case .accessoryRectangular: text(headlineLines: 2, large: false)
    case .accessoryInline: inline
    case .accessoryCircular: circular
    }
  }

  // MARK: Pieces

  private var title: Text {
    switch content {
    case .noData: IrisWidgetText.openIris
    case .idle: IrisWidgetText.idleTitle
    case .memo(let line): IrisWidgetText.title(line.phase)
    }
  }

  private var subtitle: Text {
    switch content {
    case .noData: IrisWidgetText.noDataHint
    case .idle: IrisWidgetText.idleHint
    case .memo(let line): line.headline.map { Text(verbatim: $0) } ?? IrisWidgetText.hint(line.phase)
    }
  }

  private var stateColor: Color {
    guard case .memo(let line) = content else { return context.isFullColor ? Theme.Ink.secondary : .primary }
    return context.tint(line.phase)
  }

  private var symbol: String {
    switch content {
    case .noData, .idle: "mic.fill"
    case .memo(let line): ActivityPhase(line.phase).symbol
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.xs) {
      Image(systemName: symbol)
        .accessibilityHidden(true)
      title
        .lineLimit(1)
    }
    .foregroundStyle(stateColor)
    .widgetAccentable()
  }

  @ViewBuilder private var footer: some View {
    if case .memo(let line) = content {
      HStack(spacing: Theme.Spacing.xs) {
        if let chip = line.routeChip {
          Text(verbatim: chip).lineLimit(1)
          Text(verbatim: "·").accessibilityHidden(true)
        }
        age(line.age)
      }
      .foregroundStyle(context.secondaryInk)
    }
  }

  @ViewBuilder private func age(_ age: WidgetAge) -> some View {
    switch age {
    case .since(let date): Text(date, style: .relative).lineLimit(1)
    case .text(let text): Text(verbatim: text).lineLimit(1)
    }
  }

  private func text(headlineLines: Int, large: Bool) -> some View {
    VStack(alignment: .leading, spacing: large ? Theme.Spacing.sm : Theme.Spacing.hair) {
      header.themeFont(large ? .footnote : .caption, weight: .semibold)
      subtitle
        .themeFont(large ? .subheadline : .footnote, weight: .medium)
        .foregroundStyle(context.primaryInk)
        .lineLimit(headlineLines)
        .minimumScaleFactor(0.85)
      if large { Spacer(minLength: 0) }
      if large { footer.themeFont(.caption) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// One line on the Lock Screen: the state, then the headline when there is room.
  private var inline: some View {
    let line: Text
    switch content {
    case .memo(let memo):
      line =
        memo.headline.map {
          Text(
            "\(title) · \(Text(verbatim: $0))", bundle: #bundle,
            comment: "Lock Screen inline widget: the state, then the headline")
        } ?? title
    case .noData, .idle: line = title
    }
    return Label {
      line.lineLimit(1)
    } icon: {
      Image(systemName: symbol)
    }
  }

  /// The circle is the record widget's; a last-memo circle is the state glyph.
  private var circular: some View {
    ZStack {
      Circle().fill(Color.primary.opacity(0.22))
      Image(systemName: symbol)
        .font(.system(size: 24, weight: .semibold))
        .widgetAccentable()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}
