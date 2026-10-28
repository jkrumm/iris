import SwiftUI

/// An identifier set in monospace on a subtle panel, selectable, wrapping instead of truncating.
public struct IDValueField: View {
  private let value: String

  public init(_ value: String) {
    self.value = value
  }

  public var body: some View {
    Text(verbatim: value)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(Theme.Ink.primary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Theme.Spacing.md)
      .background(Theme.Surface.subtle, in: .rect(cornerRadius: Theme.Radius.control))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.Surface.border, lineWidth: 0.5)
      }
  }
}
