import SwiftUI

/// One microphone a route can be told to record with; `id == nil` is "Automatic" (the system's choice).
public struct MicRuleChoice: Identifiable, Hashable, Sendable {
  public var id: String?
  public var title: String

  public init(id: String?, title: String) {
    self.id = id
    self.title = title
  }
}

/// The microphone rule of one audio route ("car → built-in mic"): the route's name, then the inputs to pick from, the
/// chosen one checked. The rule applies when a take starts on that route (R-CAP-4).
public struct MicRuleList: View {
  private let routeTitle: String
  private let routeCaption: String
  private let choices: [MicRuleChoice]
  private let onPick: (String?) -> Void
  private let selection: String?

  public init(
    routeTitle: String, routeCaption: String, choices: [MicRuleChoice], selection: String?,
    onPick: @escaping (String?) -> Void
  ) {
    self.routeTitle = routeTitle
    self.routeCaption = routeCaption
    self.choices = choices
    self.selection = selection
    self.onPick = onPick
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
        Text(verbatim: routeTitle)
          .themeFont(.subheadline, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
        Text(verbatim: routeCaption)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
      }
      .padding(.bottom, Theme.Spacing.sm)
      ForEach(choices) { choice in
        Button {
          onPick(choice.id)
        } label: {
          HStack {
            Text(verbatim: choice.title)
              .foregroundStyle(Theme.Ink.primary)
            Spacer(minLength: Theme.Spacing.sm)
            if choice.id == selection {
              Image(systemName: "checkmark")
                .foregroundStyle(Theme.Accent.tint)
                .accessibilityHidden(true)
            }
          }
          .themeFont(.subheadline)
          .padding(.vertical, Theme.Spacing.sm)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice.id == selection ? .isSelected : [])
        .accessibilityIdentifier("settings.mic.choice")
      }
    }
  }
}
