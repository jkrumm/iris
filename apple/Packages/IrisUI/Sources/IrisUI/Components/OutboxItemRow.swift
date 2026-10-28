import SwiftUI

/// One whole memo or chat message waiting to be sent: what it is, a line of detail, and where it stands.
public struct OutboxItemRow: View {
  public enum Status: Sendable { case waiting, sending, failed }

  private let systemImage: String
  private let title: String
  private let detail: String?
  private let status: Status
  private let statusText: String

  public init(systemImage: String, title: String, detail: String? = nil, status: Status, statusText: String) {
    self.systemImage = systemImage
    self.title = title
    self.detail = detail
    self.status = status
    self.statusText = statusText
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      Image(systemName: systemImage)
        .foregroundStyle(Theme.Ink.muted)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .themeFont(.subheadline, weight: .medium)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(1)
        if let detail {
          Text(verbatim: detail)
            .themeFont(.footnote)
            .foregroundStyle(Theme.Ink.muted)
            .lineLimit(1)
        }
      }
      Spacer(minLength: Theme.Spacing.sm)
      HStack(spacing: Theme.Spacing.xs) {
        if status == .sending { ProgressView().controlSize(.small) }
        Text(verbatim: statusText)
          .themeFont(.footnote)
          .foregroundStyle(status == .failed ? Theme.Status.warn : Theme.Ink.muted)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
