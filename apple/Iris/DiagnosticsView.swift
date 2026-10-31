import IrisCore
import IrisUI
import SwiftUI

/// Settings → Diagnostics: the memo whose id to copy, the id itself and a Copy button that confirms with "Copied".
struct DiagnosticsView: View {
  @Bindable var model: DiagnosticsModel
  let history: HistoryModel
  /// Outbox files a reset set aside; they can be shared from here.
  var quarantinedFiles: [URL] = []

  var body: some View {
    let memos = history.memos
    let recent = model.recent(memos)
    let selected = model.selectedMemo(in: memos)
    return ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.gutter) {
        ScreenTitle(String(localized: "Diagnostics", comment: "Title of the Diagnostics screen"))
        SettingsGroup(title: String(localized: "Memo", comment: "Diagnostics section")) {
          if recent.isEmpty {
            Text("No memos yet.", comment: "Diagnostics without memos")
              .themeFont(.subheadline)
              .foregroundStyle(Theme.Ink.muted)
              .settingsRow()
          } else {
            Menu {
              Picker(String(localized: "Memo", comment: "Diagnostics picker"), selection: $model.selectedID) {
                ForEach(recent) { memo in
                  Text(verbatim: "\(memo.rowHeadline) · \(memo.timeText)").tag(Optional(memo.id))
                }
              }
            } label: {
              HStack(spacing: Theme.Spacing.rowColumnGap) {
                VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
                  Text("Memo", comment: "Diagnostics picker")
                    .themeFont(.subheadline)
                    .foregroundStyle(Theme.Ink.primary)
                  if let selected {
                    Text(verbatim: selected.rowHeadline)
                      .themeFont(.footnote)
                      .foregroundStyle(Theme.Ink.muted)
                      .lineLimit(2)
                      .multilineTextAlignment(.leading)
                  }
                }
                Spacer(minLength: Theme.Spacing.sm)
                if let selected {
                  Text(verbatim: selected.timeText)
                    .themeFont(.footnote)
                    .foregroundStyle(Theme.Ink.muted)
                }
                Image(systemName: "chevron.up.chevron.down")
                  .themeFont(.footnote, weight: .semibold)
                  .foregroundStyle(Theme.Ink.faint)
                  .accessibilityHidden(true)
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .settingsRow()
            .accessibilityIdentifier("diagnostics.picker")
          }
          if let selected {
            VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
              IDValueField(selected.id)
                .accessibilityIdentifier("diagnostics.id")
              CopyButton(
                title: String(localized: "Copy memo id", comment: "Diagnostics copy button"),
                copiedTitle: String(localized: "Copied", comment: "Diagnostics copy confirmation"),
                isCopied: model.isCopied
              ) {
                model.copyID(from: memos)
              }
              .accessibilityIdentifier("diagnostics.copy")
            }
            .settingsRow()
          }
        } footer: {
          Text(
            "The trace id is this id without the dashes. Paste either into the dashboard to find the memo's trace.",
            comment: "Diagnostics footer")
        }

        if !quarantinedFiles.isEmpty {
          SettingsGroup(title: String(localized: "Set-aside outbox", comment: "Diagnostics section")) {
            ForEach(quarantinedFiles, id: \.self) { file in
              ShareLink(item: file) {
                Label {
                  Text(verbatim: file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                } icon: {
                  Image(systemName: "square.and.arrow.up")
                }
                .themeFont(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .settingsRow()
              .accessibilityIdentifier("diagnostics.quarantined")
            }
          } footer: {
            Text(
              "A reset renamed the unreadable outbox file instead of deleting it. Share it to have the queue looked at.",
              comment: "Diagnostics footer")
          }
        }
      }
      .padding(.horizontal, Theme.Spacing.screenMargin)
    }
    .accessibilityIdentifier("diagnostics.view")
    .background(Theme.Surface.background)
    .navigationBarTitleDisplayMode(.inline)
    .task { model.selectedID = model.selectedID ?? selected?.id }
    .task(id: model.copyCount) {
      guard model.isCopied, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
      model.clearCopied()
    }
  }
}
