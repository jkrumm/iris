import Foundation

/// The reply as the server stores it (Hermes's markdown) turned into styled text: emphasis, code spans and links.
/// Lists, headings, tables and Mermaid are the full conversation rendering of Wave 15; until then their markup reads
/// as plain lines, which the preserved whitespace keeps legible.
nonisolated enum ReplyMarkdown {
  static func attributed(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }
}
