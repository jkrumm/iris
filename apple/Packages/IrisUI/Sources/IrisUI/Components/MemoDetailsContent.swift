import SwiftUI

/// What one memo's Details show, the same on the iPhone (the Details sheet) and the Mac (the toolbar popover): the run's line
/// ("Details", duration and cost) over every step with its bar, attempts and Retry, then the copy rows, the tools Hermes used and
/// the ids to quote when something is wrong. The apps own the data and the actions; this view draws what it is given. It starts
/// open: whoever opened Details came for the steps, and the line still folds them.
public struct MemoDetailsContent: View {
  /// One row that copies the transcript or the reply as plain text; `id` is `transcript` or `reply`.
  public struct CopyRow: Identifiable {
    public let id: String
    public let title: String
    public let isCopied: Bool
    public let action: () -> Void

    public init(id: String, title: String, isCopied: Bool, action: @escaping () -> Void) {
      self.id = id
      self.title = title
      self.isCopied = isCopied
      self.action = action
    }
  }

  private let rows: [StepWaterfallRow]
  private let totalValue: String
  private let copyRows: [CopyRow]
  private let tools: [String]
  private let memoID: String
  private let threadID: String?
  private let device: String
  private let segmentCount: Int?
  private let onRetry: (String) -> Void
  @State private var isExpanded = true

  /// - Parameters:
  ///   - totalValue: The run's `duration · cost`, empty before the steps have loaded (the line stays).
  ///   - tools: The tools Hermes used, names as data; nothing is drawn when empty.
  ///   - threadID: Only when it differs from the memo's id (a memo in its own Hermes session has the memo's id as its thread id).
  ///   - segmentCount: The recording's uploaded segments, when known.
  ///   - onRetry: Called with the id of the step whose Retry was tapped.
  public init(
    rows: [StepWaterfallRow], totalValue: String, copyRows: [CopyRow], tools: [String], memoID: String,
    threadID: String?, device: String, segmentCount: Int?, onRetry: @escaping (String) -> Void
  ) {
    self.rows = rows
    self.totalValue = totalValue
    self.copyRows = copyRows
    self.tools = tools
    self.memoID = memoID
    self.threadID = threadID
    self.device = device
    self.segmentCount = segmentCount
    self.onRetry = onRetry
  }

  public var body: some View {
    StepWaterfall(
      rows: rows,
      totalTitle: String(
        localized: "Details", bundle: #bundle, comment: "Section line of a memo's details: steps, cost, ids"),
      totalValue: totalValue, isExpanded: $isExpanded, onRetry: onRetry
    ) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(copyRows) { copyRow($0) }
        toolsLine
        idsFooter
      }
    }
  }

  private func copyRow(_ row: CopyRow) -> some View {
    VStack(spacing: 0) {
      Button(action: row.action) {
        Label {
          if row.isCopied {
            Text("Copied", bundle: #bundle, comment: "Details: confirmation after Copy")
          } else {
            Text(verbatim: row.title)
          }
        } icon: {
          Image(systemName: row.isCopied ? "checkmark" : "doc.on.doc")
        }
        .themeFont(.subheadline)
        .foregroundStyle(row.isCopied ? Theme.Status.good : Theme.Accent.tint)
        .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
        .padding(.vertical, Theme.Spacing.cardInsetVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .sensoryFeedback(.success, trigger: row.isCopied) { _, now in now }
      .accessibilityIdentifier("detail.\(row.id).copy")
      Theme.divider.frame(height: 1)
    }
  }

  /// What Hermes used for the memo, one quiet line; nothing when it used no tool.
  @ViewBuilder private var toolsLine: some View {
    if !tools.isEmpty {
      let names = tools.joined(separator: ", ")
      Text(
        "Hermes used: \(names)", bundle: #bundle, comment: "Details: the tools Hermes ran for the memo, names are data"
      )
      .themeFont(.caption)
      .foregroundStyle(Theme.Ink.muted)
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.cardInsetVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("detail.actions")
    }
  }

  /// The ids to quote when something is wrong, then the device and the recording's segments.
  private var idsFooter: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      idRow(Text("Memo ID", bundle: #bundle, comment: "Details: label of the memo's id"), memoID)
      if let threadID, threadID != memoID {
        idRow(Text("Thread ID", bundle: #bundle, comment: "Details: label of the thread's id"), threadID)
      }
      deviceLine
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.faint)
    }
    .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
    .padding(.vertical, Theme.Spacing.cardInsetVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("detail.ids")
  }

  private func idRow(_ title: Text, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
      title
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      IDValueField(value)
    }
  }

  /// The device, then the recording's segments when known ("iphone · 2 segments").
  @ViewBuilder private var deviceLine: some View {
    if let segmentCount {
      HStack(spacing: 0) {
        Text(verbatim: device + " · ")
        Text("\(segmentCount) segments", bundle: #bundle, comment: "Details: uploaded recording segments")
      }
      .accessibilityElement(children: .combine)
    } else {
      Text(verbatim: device)
    }
  }
}
