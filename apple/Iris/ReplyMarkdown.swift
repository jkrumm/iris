import Foundation

/// The reply as the server stores it (Hermes's markdown) read by Foundation.
nonisolated enum ReplyMarkdown {
  /// The one markdown parse of the app's replies (Copy's block-aware plain text); nil when Foundation cannot read the text at all.
  static func parse(
    _ text: String, syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
  ) -> AttributedString? {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: syntax, failurePolicy: .returnPartiallyParsedIfPossible)
    return try? AttributedString(markdown: text, options: options)
  }
}
