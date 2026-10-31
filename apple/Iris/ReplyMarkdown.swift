import Foundation

/// The reply as the server stores it (Hermes's markdown) turned into styled text: emphasis, code spans and links.
/// Lists, headings, tables and Mermaid are the full conversation rendering of Wave 15; until then their markup reads
/// as plain lines, which the preserved whitespace keeps legible.
nonisolated enum ReplyMarkdown {
  static func attributed(_ text: String) -> AttributedString {
    parse(text, syntax: .inlineOnlyPreservingWhitespace) ?? AttributedString(text)
  }

  /// The one markdown parse of the app's replies (the screen's inline styling and Copy's block-aware plain text share it);
  /// nil when Foundation cannot read the text at all.
  static func parse(
    _ text: String, syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
  ) -> AttributedString? {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: syntax, failurePolicy: .returnPartiallyParsedIfPossible)
    return try? AttributedString(markdown: text, options: options)
  }
}
