import SwiftUI

/// The color of a memo kind (Hermes' free-form label) for the History row dot and the kind chip. The kinds the pipeline
/// is known to produce get one of the series colors; any other kind, and a memo without one, is neutral.
public enum KindPalette {
  public static func color(forKind kind: String?) -> Color {
    guard let kind else { return Theme.Ink.faint }
    switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "answer": return SeriesPalette.blue
    case "task": return SeriesPalette.orange
    case "note": return SeriesPalette.green
    case "github issue": return SeriesPalette.purple
    case "chat": return Theme.Accent.tint
    default: return Theme.Ink.faint
    }
  }
}
