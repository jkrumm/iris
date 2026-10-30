import IrisCore
import IrisUI
import SwiftUI

/// One destination Iris can route a memo to, as the review screens show it (docs/design/README.md, Wave 17 I6). The
/// destinations are the server's fixed three; whether one is available depends on what the server registered at boot
/// (`BRAIN_DIR` for journal, `HERDR_SOCKET` for herdr), so the phone can only read this, never change it.
struct RouteConfigDestination: Identifiable {
  let kind: RouteDestination
  /// `false` when the server has no adapter for it: it is not a routing choice and a memo that names it parks at needs-route.
  let isAvailable: Bool

  var id: RouteDestination { kind }

  /// The server this render pretends to talk to: Hermes and herdr registered, journal not (the case worth seeing).
  static let sample: [RouteConfigDestination] = [
    RouteConfigDestination(kind: .hermes, isAvailable: true),
    RouteConfigDestination(kind: .journal, isAvailable: false),
    RouteConfigDestination(kind: .herdr, isAvailable: true),
  ]

  var title: String {
    switch kind {
    case .hermes: String(localized: "Hermes", comment: "Route destination")
    case .journal: String(localized: "Journal", comment: "Route destination")
    case .herdr: String(localized: "Herdr tab", comment: "Route destination")
    }
  }

  var systemImage: String {
    switch kind {
    case .hermes: "sparkles"
    case .journal: "book.closed"
    case .herdr: "terminal"
    }
  }

  /// The same dot colour a History row gives the route.
  var dot: Color {
    switch kind {
    case .hermes: Theme.Accent.tint
    case .journal: Theme.Status.good
    case .herdr: Theme.Ink.secondary
    }
  }

  /// One line under the name on the overview: what lands where.
  var summary: String {
    switch kind {
    case .hermes: String(localized: "A conversation with your agent", comment: "Route destination summary")
    case .journal: String(localized: "A note in the brain inbox", comment: "Route destination summary")
    case .herdr: String(localized: "Text typed into a running agent tab", comment: "Route destination summary")
    }
  }

  /// What the destination does with the transcript.
  var explanation: String {
    switch kind {
    case .hermes:
      String(
        localized:
          "The transcript starts a new Hermes session and the answer comes back as the reply. A chat memo, or a reply inside a thread, continues the same session.",
        comment: "Route destination explanation")
    case .journal:
      String(
        localized:
          "The transcript is written as a note into the brain inbox, then committed and pushed. There is no reply, so the memo ends with the note.",
        comment: "Route destination explanation")
    case .herdr:
      String(
        localized:
          "The transcript is typed into the agent pane of one live herdr tab and sent with Enter. Which tab is decided per memo; the tab's answer stays in the terminal.",
        comment: "Route destination explanation")
    }
  }

  /// The words that send a memo here when said first ("journal, buy milk"). Mode picks win over these.
  var spokenPrefixes: [String] {
    switch kind {
    case .hermes:
      [
        String(localized: "hermes", comment: "Spoken route prefix"),
        String(localized: "an hermes", comment: "Spoken route prefix"),
      ]
    case .journal:
      [
        String(localized: "journal", comment: "Spoken route prefix"),
        String(localized: "tagebuch", comment: "Spoken route prefix"),
      ]
    case .herdr: [String(localized: "tab <name>", comment: "Spoken route prefix, the placeholder is a tab name")]
    }
  }

  /// The record modes that name this destination.
  var modes: [String] {
    switch kind {
    case .hermes:
      [String(localized: "Hermes", comment: "Record mode"), String(localized: "Chat", comment: "Record mode")]
    case .journal: [String(localized: "Journal", comment: "Record mode")]
    case .herdr: [String(localized: "Tab", comment: "Record mode")]
    }
  }

  /// Why it is not available, and what makes it so; only for an unavailable destination.
  var unavailableReason: String? {
    guard !isAvailable else { return nil }
    switch kind {
    case .hermes:
      return String(localized: "The server has no Hermes connection.", comment: "Route destination unavailable")
    case .journal:
      return String(
        localized: "The server has no brain checkout, so there is nowhere to write a note.",
        comment: "Route destination unavailable")
    case .herdr:
      return String(localized: "The server cannot reach herdr.", comment: "Route destination unavailable")
    }
  }

  /// The overview's status text: availability, and the live tab count for herdr.
  func status(tabCount: Int) -> String {
    guard isAvailable else { return String(localized: "Not set up", comment: "Route destination status") }
    guard kind == .herdr else { return String(localized: "Available", comment: "Route destination status") }
    return String(localized: "\(tabCount) tabs live", comment: "Route destination status, the placeholder is a count")
  }
}
