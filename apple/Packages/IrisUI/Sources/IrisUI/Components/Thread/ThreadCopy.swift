import Foundation

/// The thread screen's text that has a plural, kept where the string catalog is.
public enum ThreadCopy {
  /// "1 turn", "3 turns" ("1 Runde", "3 Runden"): the catalog's plural variants pick the form.
  public static func turnCount(_ count: Int) -> String {
    turnCount(count, in: #bundle)
  }

  /// The same, looked up in `bundle` (a language's `.lproj` in tests, since a locale does not choose the language).
  static func turnCount(_ count: Int, in bundle: Bundle) -> String {
    String(
      localized: "\(count) turns", bundle: bundle,
      comment: "Number of turns (questions asked) of a thread, in its header")
  }
}
