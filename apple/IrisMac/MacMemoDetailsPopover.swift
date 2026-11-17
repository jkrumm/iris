import IrisCore
import IrisUI
import SwiftUI

/// The detail pane's Details popover, opened from its toolbar: the same ``MemoDetailsContent`` the iPhone's sheet shows (step
/// waterfall with Retry, copy rows, the tools Hermes used, ids). A conversation steps through its answers with Previous and Next;
/// the popover opens on the memo the pane shows, which keeps its own model. The other memos get a model each, built when first
/// shown, that loads its steps itself.
struct MacMemoDetailsPopover: View {
  let root: MacCompositionRoot
  let model: MacMemoDetailModel
  @State private var selectedID: String

  private static let width: CGFloat = 400
  private static let maxHeight: CGFloat = 520

  init(root: MacCompositionRoot, model: MacMemoDetailModel) {
    self.root = root
    self.model = model
    _selectedID = State(initialValue: model.memoID)
  }

  /// Every memo of the conversation, oldest first; the open memo alone when it has no thread.
  private var memos: [Memo] {
    model.thread?.memos ?? model.memo.map { [$0] } ?? []
  }

  private var index: Int? { memos.firstIndex { $0.id == selectedID } }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
      if memos.count > 1, let index { stepper(at: index) }
      // Short content sits at its own height; long content scrolls under the cap.
      ViewThatFits(in: .vertical) {
        page
        ScrollView { page }
      }
    }
    .padding(Theme.Spacing.macDetailMargin)
    .frame(width: Self.width)
    .frame(maxHeight: Self.maxHeight)
    .accessibilityIdentifier("mac.detail.details.popover")
  }

  @ViewBuilder private var page: some View {
    if selectedID == model.memoID {
      MacMemoDetailsPage(model: model, refreshToken: nil)
    } else if let memo = memos.first(where: { $0.id == selectedID }) {
      BuiltOnce(make: { root.detailsModel(for: memo) }) { other in
        // Reloads on the window's revision of the memo, as the iPhone's sheet does.
        MacMemoDetailsPage(model: other, refreshToken: root.windowHistory.revision(of: memo.id))
      }
      .id(memo.id)
    }
  }

  private func stepper(at index: Int) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
      Text(
        verbatim: String(
          localized: "Answer \(index + 1) of \(memos.count)",
          comment: "Details popover: which memo of the conversation")
      )
      .macFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      Spacer()
      Button(
        String(localized: "Earlier answer", comment: "Details popover: shows the previous memo"),
        systemImage: "chevron.up"
      ) { selectedID = memos[index - 1].id }
      .disabled(index == 0)
      .accessibilityIdentifier("mac.detail.details.previous")
      Button(
        String(localized: "Later answer", comment: "Details popover: shows the next memo"),
        systemImage: "chevron.down"
      ) { selectedID = memos[index + 1].id }
      .disabled(index == memos.count - 1)
      .accessibilityIdentifier("mac.detail.details.next")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
  }
}

/// One memo's page: the kind chip and meta line, the error of a failed memo, then the shared Details.
private struct MacMemoDetailsPage: View {
  let model: MacMemoDetailModel
  /// The pane loads the memo it shows (`nil`); the popover loads every other one, again whenever this changes.
  let refreshToken: Int?

  var body: some View {
    if let memo = model.memo {
      VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
        header(memo)
        if memo.state.isResultReady {
          section(memo, now: .now)
        } else {
          // A running step's bar grows with the clock.
          TimelineView(.periodic(from: .now, by: 1)) { context in
            section(memo, now: context.date)
          }
        }
        if let failure = model.failure {
          Text(verbatim: failure).macFont(.body).foregroundStyle(Theme.Status.bad)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task(id: refreshToken) { if refreshToken != nil { await model.load() } }
    }
  }

  private func header(_ memo: Memo) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macHeaderGap) {
      HStack(spacing: Theme.Spacing.snug) {
        KindChip(label: memo.kindLabel, systemImage: memo.kindIcon)
        Text(verbatim: metadata(memo)).lineLimit(1)
      }
      .macFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      if memo.state == .failed, let error = memo.error {
        Text(verbatim: error).macFont(.body).foregroundStyle(Theme.Status.bad).textSelection(.enabled)
      }
    }
  }

  private func metadata(_ memo: Memo) -> String {
    let cost = model.detail.flatMap { WaterfallBuilder.totals(for: $0, now: .now)?.costUsd }
    return [
      memo.createdAt.formatted(date: .abbreviated, time: .shortened),
      cost.map { StepText.dollars($0) },
    ]
    .compactMap { $0 }.joined(separator: " · ")
  }

  private func section(_ memo: Memo, now: Date) -> some View {
    MemoDetailsContent(
      rows: model.rows(now: now), totalValue: model.totalValue(now: now) ?? "", copyRows: copyRows(memo),
      tools: memo.actions, memoID: memo.id, threadID: memo.threadId, device: memo.device,
      segmentCount: memo.segmentCount,
      onRetry: { id in
        guard let step = MemoStep(rawValue: id) else { return }
        Task { await model.retry(from: step) }
      })
  }

  private func copyRows(_ memo: Memo) -> [MemoDetailsContent.CopyRow] {
    var rows: [MemoDetailsContent.CopyRow] = []
    if memo.plainTranscript != nil {
      rows.append(
        MemoDetailsContent.CopyRow(
          id: "transcript",
          title: String(localized: "Copy transcript", comment: "Detail toolbar menu"),
          isCopied: model.copied == .transcript, action: { model.copy(.transcript) }))
    }
    if memo.plainReply != nil {
      rows.append(
        MemoDetailsContent.CopyRow(
          id: "reply", title: String(localized: "Copy reply", comment: "Detail toolbar menu"),
          isCopied: model.copied == .reply, action: { model.copy(.reply) }))
    }
    return rows
  }
}
