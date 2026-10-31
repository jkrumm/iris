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
    return List {
      Section {
        if recent.isEmpty {
          Text("No memos yet.", comment: "Diagnostics without memos")
            .foregroundStyle(Theme.Ink.muted)
        } else {
          Picker(String(localized: "Memo", comment: "Diagnostics picker"), selection: $model.selectedID) {
            ForEach(recent) { memo in
              Text(verbatim: "\(memo.rowHeadline) · \(memo.timeText)")
                .lineLimit(1)
                .tag(Optional(memo.id))
            }
          }
          .labelsHidden()
          .accessibilityIdentifier("diagnostics.picker")
        }
        if let selected {
          VStack(alignment: .leading, spacing: Theme.Spacing.md) {
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
          .listRowSeparator(.hidden)
        }
      } header: {
        Text("Memo", comment: "Diagnostics section")
      } footer: {
        Text(
          "The trace id is this id without the dashes. Paste either into the dashboard to find the memo's trace.",
          comment: "Diagnostics footer")
      }
      .listRowBackground(Theme.Surface.panel)

      Section {
        TextField(String(localized: "Run id", comment: "Diagnostics run id field"), text: $model.runID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityIdentifier("diagnostics.runid")
      } header: {
        Text("Run", comment: "Diagnostics section")
      } footer: {
        Text(
          "One word for a round of testing. Every device log record carries it, so one filter finds the whole round.",
          comment: "Diagnostics footer")
      }
      .listRowBackground(Theme.Surface.panel)

      if !quarantinedFiles.isEmpty {
        Section {
          ForEach(quarantinedFiles, id: \.self) { file in
            ShareLink(item: file) {
              Label {
                Text(verbatim: file.lastPathComponent).lineLimit(1).truncationMode(.middle)
              } icon: {
                Image(systemName: "square.and.arrow.up")
              }
            }
            .accessibilityIdentifier("diagnostics.quarantined")
          }
        } header: {
          Text("Set-aside outbox", comment: "Diagnostics section")
        } footer: {
          Text(
            "A reset renamed the unreadable outbox file instead of deleting it. Share it to have the queue looked at.",
            comment: "Diagnostics footer")
        }
        .listRowBackground(Theme.Surface.panel)
      }
    }
    .accessibilityIdentifier("diagnostics.view")
    .scrollContentBackground(.hidden)
    .background(Theme.Surface.background)
    .navigationTitle(String(localized: "Diagnostics", comment: "Navigation title"))
    .navigationBarTitleDisplayMode(.inline)
    .task { model.selectedID = model.selectedID ?? selected?.id }
    .task(id: model.copyCount) {
      guard model.isCopied, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
      model.clearCopied()
    }
  }
}
