import Foundation

/// Every control the Mac offers on a memo, in the detail toolbar and in the row's context menu, with the tooltip (`.help`) that
/// says what it does and what it acts on. One table, so a control cannot ship without its tooltip: the views read `help`, and a
/// test walks `allCases`.
enum MacMemoControl: CaseIterable {
  case readReply, stopReply, readSummary, readFull
  case playRecording, stopRecording, more
  case continueRecording
  case copyMenu, copyTranscript, copyReply
  case retryMenu, details
  case favorite, unfavorite, archive, unarchive, delete
  case done, notDone

  var help: String {
    switch self {
    case .readReply:
      String(
        localized: "Read the reply aloud (summary)", comment: "Tooltip of the speaker button: plays the spoken summary")
    case .stopReply:
      String(localized: "Stop reading the reply", comment: "Tooltip of the speaker button while the reply speaks")
    case .readSummary:
      String(
        localized: "Read the short summary of the reply aloud", comment: "Tooltip of the speaker menu's summary entry")
    case .readFull:
      String(localized: "Read the whole reply aloud", comment: "Tooltip of the speaker menu's full-reply entry")
    case .playRecording:
      String(localized: "Play your recording", comment: "Tooltip: plays what the user said, not the reply")
    case .stopRecording:
      String(localized: "Stop your recording", comment: "Tooltip: stops the user's recording")
    case .more:
      String(localized: "More actions for this memo", comment: "Tooltip of the toolbar's overflow menu")
    case .continueRecording:
      String(
        localized: "Record more and add it to this transcript", comment: "Tooltip of the toolbar's Continue recording")
    case .copyMenu:
      String(localized: "Copy the transcript or the reply", comment: "Tooltip of the toolbar's Copy menu")
    case .copyTranscript:
      String(localized: "Copy the transcript as plain text", comment: "Tooltip of the Copy menu's transcript entry")
    case .copyReply:
      String(localized: "Copy the reply as plain text", comment: "Tooltip of the Copy menu's reply entry")
    case .retryMenu:
      String(localized: "Retry the memo from one of its failed steps", comment: "Tooltip of the Retry menu")
    case .details:
      String(localized: "Show the steps, costs and ids of this answer", comment: "Tooltip of the Details button")
    case .favorite:
      String(localized: "Add this memo to your favorites", comment: "Tooltip of Favorite")
    case .unfavorite:
      String(localized: "Remove this memo from your favorites", comment: "Tooltip of Unfavorite")
    case .archive:
      String(localized: "Move this memo to the archive", comment: "Tooltip of Archive")
    case .unarchive:
      String(localized: "Move this memo back out of the archive", comment: "Tooltip of Unarchive")
    case .delete:
      String(localized: "Delete this memo (you can undo it for a few seconds)", comment: "Tooltip of Delete")
    case .done:
      String(localized: "Mark this memo as done", comment: "Tooltip of Done")
    case .notDone:
      String(localized: "Mark this memo as not done", comment: "Tooltip of Not done")
    }
  }

  /// Retry of a single failed step names the step.
  static func retry(from step: String) -> String {
    String(localized: "Retry from \(step)", comment: "Button on the step a memo failed at")
  }
}
