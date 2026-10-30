import Foundation

/// The Settings "Server" row: what the saved connection amounts to right now. The health probe (once, when Settings appears)
/// and the app's live traffic (``ServerLink``) are combined, so "Connected" is never shown for a server the app cannot reach.
struct ConnectionStatusLine: Equatable {
  enum Tone: Equatable {
    case good, warn, bad, muted
  }

  let title: String
  /// A short line under the row that says what to check; nil when there is nothing to do.
  let hint: String?
  let tone: Tone

  init(connection: SettingsModel.Connection, link: ServerLink) {
    switch (connection, link) {
    case (.notConfigured, _):
      self.init(
        String(localized: "Not configured", comment: "Server connection"), tone: .warn)
    case (_, .rejected):
      self.init(
        String(localized: "Token rejected", comment: "Server connection"),
        hint: String(
          localized: "The server did not accept this device's token. Check it below.",
          comment: "Settings connection hint: the token was refused"),
        tone: .bad)
    case (_, .unreachable), (.unreachable, .unknown):
      self.init(
        String(localized: "Unreachable", comment: "Server connection"),
        hint: String(
          localized: "Server not reachable — is Tailscale on?",
          comment: "Settings connection hint: the server cannot be reached"),
        tone: .bad)
    case (.unreachable, .live), (.connected, _):
      self.init(String(localized: "Connected", comment: "Server connection"), tone: .good)
    case (.checking, _):
      self.init(String(localized: "Checking…", comment: "Server connection"), tone: .muted)
    case (.degraded(let names), _):
      self.init(
        names.isEmpty
          ? String(localized: "Degraded", comment: "Server connection")
          : String(localized: "Degraded · \(names.joined(separator: ", "))", comment: "Server connection"),
        tone: .warn)
    }
  }

  private init(_ title: String, hint: String? = nil, tone: Tone) {
    self.title = title
    self.hint = hint
    self.tone = tone
  }
}
