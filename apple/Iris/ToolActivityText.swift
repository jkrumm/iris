import Foundation

/// The words for a tool Hermes started while `act` runs. The wire name is the Iris action name: the tool's own for most tools,
/// the loaded skill's for `skill_view`, and the two cannot be told apart, so a name never claims to be one or the other.
enum ToolActivityText {
  static func label(for tool: String) -> String {
    switch tool {
    case "terminal":
      String(localized: "Using terminal", comment: "Live line of a running answer: Hermes runs a shell command")
    case "web":
      String(localized: "Searching the web", comment: "Live line of a running answer: Hermes searches the web")
    default:
      String(
        localized: "Using \(tool)",
        comment: "Live line of a running answer: Hermes uses a tool or skill; the placeholder is its name")
    }
  }
}
