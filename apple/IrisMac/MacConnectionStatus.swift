import Foundation

/// The panel header's connection line: what History's own authenticated traffic says about the server (``ServerLink``), so
/// "Connected" is never shown for a server the app cannot reach.
struct MacConnectionStatus: Equatable {
  enum Tone: Equatable {
    case good, warn, bad, muted
  }

  let title: String
  /// What to check; nil when there is nothing to do.
  let hint: String?
  let tone: Tone

  init(isConfigured: Bool, link: ServerLink) {
    switch (isConfigured, link) {
    case (false, _):
      self.init(String(localized: "Not configured", comment: "Server connection"), tone: .warn)
    case (_, .rejected):
      self.init(
        String(localized: "Token rejected", comment: "Server connection"),
        hint: String(
          localized: "The server did not accept this device's token. Check it in Settings.",
          comment: "Connection hint: the token was refused"),
        tone: .bad)
    case (_, .unreachable):
      self.init(
        String(localized: "Unreachable", comment: "Server connection"),
        hint: String(
          localized: "Server not reachable — is Tailscale on?", comment: "Connection hint: the server cannot be reached"
        ),
        tone: .bad)
    case (_, .live):
      self.init(String(localized: "Connected", comment: "Server connection"), tone: .good)
    case (_, .unknown):
      self.init(String(localized: "Connecting…", comment: "Server connection"), tone: .muted)
    }
  }

  private init(_ title: String, hint: String? = nil, tone: Tone) {
    self.title = title
    self.hint = hint
    self.tone = tone
  }
}
