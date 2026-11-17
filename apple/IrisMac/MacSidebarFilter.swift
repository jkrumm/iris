import IrisCore
import IrisUI
import SwiftUI

/// The lower part of the main window's sidebar: the memo kinds present in the loaded memos and the states the iPhone's filter sheet
/// offers, as toggles over the window's list (the same ``HistoryFilters`` kind and state, so the list request carries the same
/// parameters). One click on Clear removes both; the scope and the search stay.
struct MacSidebarFilter: View {
  let root: MacCompositionRoot

  var body: some View {
    let filters = root.windowHistory.filters
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      HStack {
        Text("Filter", comment: "Sidebar group: narrows the memo list by kind and state")
          .macFont(.caption, weight: .semibold)
          .foregroundStyle(Theme.Ink.muted)
          .textCase(.uppercase)
        Spacer(minLength: 0)
        if filters.hasKindOrState {
          Button(String(localized: "Clear", comment: "Sidebar: removes the kind and state filter")) {
            root.clearKindAndStateFilter()
          }
          .buttonStyle(.link)
          .macFont(.caption)
          .help(
            String(
              localized: "Show all kinds and states again", comment: "Tooltip of Clear in the sidebar's filter")
          )
          .accessibilityIdentifier("mac.sidebar.filter.clear")
        }
      }
      let kinds = root.filterKinds
      if !kinds.isEmpty {
        group(String(localized: "Kind", comment: "Sidebar filter group")) {
          ForEach(kinds, id: \.self) { kind in
            MacFilterChip(
              title: Memo.capitalizedKind(kind), dot: KindPalette.color(forKind: kind),
              isOn: filters.isSelected(kind: kind)
            ) {
              root.toggleKindFilter(kind)
            }
            .accessibilityIdentifier("mac.sidebar.filter.kind.\(kind)")
          }
        }
      }
      group(String(localized: "State", comment: "Sidebar filter group")) {
        ForEach(MacCompositionRoot.filterStates, id: \.self) { state in
          MacFilterChip(title: state.label, dot: state.color, isOn: filters.state == state) {
            root.toggleStateFilter(state)
          }
          .accessibilityIdentifier("mac.sidebar.filter.state.\(state.rawValue)")
        }
      }
    }
    .padding(.horizontal, Theme.Spacing.cozy)
    .padding(.vertical, Theme.Spacing.sm)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mac.sidebar.filter")
  }

  private func group(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      Text(verbatim: title).macFont(.caption).foregroundStyle(Theme.Ink.muted)
      ChipFlowLayout(spacing: Theme.Spacing.xs, lineSpacing: Theme.Spacing.xs) { chips() }
    }
  }
}

/// A capsule toggle at the desktop's size (11 pt, no 44 pt tap area); the filled capsule is the active filter.
struct MacFilterChip: View {
  let title: String
  let dot: Color
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.xs) {
        Circle()
          .fill(isOn ? Theme.Accent.onFill : dot)
          .frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
          .accessibilityHidden(true)
        Text(verbatim: title).lineLimit(1)
      }
      .macFont(.caption, weight: .medium)
      .foregroundStyle(isOn ? Theme.Accent.onFill : Theme.Ink.secondary)
      .padding(.horizontal, Theme.Spacing.snug)
      .padding(.vertical, Theme.Spacing.xs)
      .background(isOn ? Theme.Accent.fill : Theme.Surface.subtle, in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: isOn ? 0 : 0.5) }
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// The main window's toolbar action: starts a transcript-only take (the popover's Transcribe, with the same recording panel);
/// while any take runs it is Stop.
struct MacTranscribeButton: View {
  let root: MacCompositionRoot

  var body: some View {
    let recording = root.recording.isRecording
    Button {
      root.toggleTranscribe()
    } label: {
      if recording {
        Label(String(localized: "Stop", comment: "Stops the take"), systemImage: "stop.fill")
      } else {
        Label(
          String(localized: "Transcribe", comment: "Starts a transcript-only take from the main window's toolbar"),
          systemImage: "text.alignleft")
      }
    }
    .keyboardShortcut("t", modifiers: [.command, .shift])
    .help(
      recording
        ? String(
          localized: "Stop the take and transcribe it", comment: "Tooltip of the toolbar's Transcribe while a take runs"
        )
        : String(
          localized: "Record a take and get its transcript only (⇧⌘T)",
          comment: "Tooltip of the toolbar's Transcribe"
        )
    )
    .accessibilityIdentifier(recording ? "mac.toolbar.stop" : "mac.toolbar.transcribe")
  }
}
