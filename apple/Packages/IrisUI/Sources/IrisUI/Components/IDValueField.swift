import SwiftUI

/// An identifier set in monospace on a subtle panel, selectable, on one line: it scales down to fit
/// instead of wrapping, since an id broken mid-way reads as two ids.
public struct IDValueField: View {
  private let value: String

  public init(_ value: String) {
    self.value = value
  }

  public var body: some View {
    Text(verbatim: value)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(Theme.Ink.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Theme.Spacing.md)
      .background(Theme.Surface.subtle, in: .rect(cornerRadius: Theme.Radius.control))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.Surface.border, lineWidth: 0.5)
      }
  }
}
