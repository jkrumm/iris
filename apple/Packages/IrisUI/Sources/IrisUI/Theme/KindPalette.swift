import Foundation
import SwiftUI

/// The color and the name of a memo kind (Hermes' free-form label) for the History row dot, the kind chip and the filter.
/// The kinds the pipeline is known to produce get one of the series colors and a localized name; any other kind, and a
/// memo without one, is neutral and shown as sent. ``normalized(_:)`` is the one place a kind is trimmed and lower-cased.
public enum KindPalette {
  /// The kind as it is compared and matched: trimmed, lower-cased.
  public static func normalized(_ kind: String) -> String {
    kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The localized name of a known kind, nil for any other (free-form data, shown verbatim by the caller).
  public static func localizedName(forKind kind: String) -> String? {
    switch normalized(kind) {
    case "answer": String(localized: "Answer", bundle: #bundle, comment: "Memo kind chip: Hermes answered a question")
    case "task": String(localized: "Task", bundle: #bundle, comment: "Memo kind chip: Hermes did a piece of work")
    case "note": String(localized: "Note", bundle: #bundle, comment: "Memo kind chip: Hermes saved a note")
    case "github issue":
      String(localized: "GitHub issue", bundle: #bundle, comment: "Memo kind chip: Hermes filed an issue")
    case "chat": String(localized: "Chat", bundle: #bundle, comment: "Memo kind chip: a conversation")
    default: nil
    }
  }

  public static func color(forKind kind: String?) -> Color {
    guard let kind else { return Theme.Ink.faint }
    switch normalized(kind) {
    case "answer": return SeriesPalette.blue
    case "task": return SeriesPalette.orange
    case "note": return SeriesPalette.green
    case "github issue": return SeriesPalette.purple
    case "chat": return Theme.Accent.tint
    default: return Theme.Ink.faint
    }
  }
}
