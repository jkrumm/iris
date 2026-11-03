import IrisCore
import IrisUI
import SwiftUI

/// "Where should this go?" in the detail pane: why the memo parked, one button per destination (the model's suggestion marked),
/// and for herdr the live tabs to pick from. A destination without a tab sends at once; a tab sends when picked. The same bar
/// corrects the route of a finished memo (then it says the answer is only logged). All logic is ``RouteAnswerModel``'s.
struct MacRouteAnswerBar: View {
  @State private var model: RouteAnswerModel
  private let onRouted: (Memo) -> Void

  init(model: RouteAnswerModel, onRouted: @escaping (Memo) -> Void) {
    _model = State(initialValue: model)
    self.onRouted = onRouted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.snug) {
        Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.Status.warn).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
          Text(
            model.kind == .answer
              ? String(localized: "Where should this go?", comment: "Detail: parked memo")
              : String(localized: "Send it somewhere else", comment: "Detail: corrects the route of a finished memo")
          )
          .macFont(.body, weight: .semibold)
          if let reason = model.reason {
            Text(verbatim: reason).macFont(.caption).foregroundStyle(Theme.Ink.muted)
          }
        }
      }
      HStack(spacing: Theme.Spacing.sm) {
        ForEach(RouteDestination.allCases, id: \.self) { destination in
          destinationButton(destination)
        }
      }
      tabs
      if model.kind == .correction {
        Text("Only logged: nothing is sent again.", comment: "Route correction note")
          .macFont(.caption).foregroundStyle(Theme.Ink.muted)
      }
      if let failure = model.failure {
        Text(verbatim: failure).macFont(.caption).foregroundStyle(Theme.Status.bad)
          .accessibilityIdentifier("mac.route.error")
      }
    }
    .padding(Theme.Spacing.macBarInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.Status.warn.opacity(0.10), in: .rect(cornerRadius: Theme.Spacing.macBarRadius))
    .disabled(model.isSubmitting)
    .accessibilityIdentifier("mac.route.bar")
  }

  private func destinationButton(_ destination: RouteDestination) -> some View {
    Button {
      choose(destination)
    } label: {
      HStack(spacing: Theme.Spacing.xs) {
        Circle().fill(destination.dotColor).frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
          .accessibilityHidden(true)
        Text(verbatim: destination.title)
        if model.suggestion == destination && model.kind == .answer {
          Image(systemName: "sparkles").foregroundStyle(Theme.Accent.tint)
            .help(String(localized: "Suggested", comment: "Route bar: the model's guess"))
        }
      }
      .macFont(.body)
    }
    .buttonStyle(.bordered)
    .tint(model.destination == destination && destination == .herdr ? Theme.Accent.tint : nil)
    .accessibilityIdentifier("mac.route.\(destination.rawValue)")
  }

  @ViewBuilder private var tabs: some View {
    switch model.tabs {
    case .notNeeded:
      EmptyView()
    case .loading:
      ProgressView().controlSize(.small)
    case .unavailable(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .macFont(.caption).foregroundStyle(Theme.Status.warn)
    case .loaded(let tabs):
      VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
        ForEach(tabs) { tab in
          Button {
            model.tab = tab.id
            send()
          } label: {
            HStack(spacing: Theme.Spacing.sm) {
              Text(verbatim: tab.title).macFont(.body, weight: .medium)
              Text(verbatim: tab.subtitle).macFont(.caption).foregroundStyle(Theme.Ink.muted)
              Spacer(minLength: 0)
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .padding(.vertical, Theme.Spacing.hair)
          .accessibilityIdentifier("mac.route.tab")
        }
      }
    }
  }

  private func choose(_ destination: RouteDestination) {
    model.destination = destination
    if destination == .herdr {
      Task { await model.loadHerd() }
    } else {
      send()
    }
  }

  private func send() {
    Task {
      guard let routed = await model.submit() else { return }
      onRouted(routed)
    }
  }
}
