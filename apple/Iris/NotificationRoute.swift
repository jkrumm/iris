import Foundation
import IrisCore
import UserNotifications

/// What a tap on a `MEMO_DONE` notification, or on one of its actions, asks the app to do. Pure: the notification center
/// delegate (``PushAppDelegate``) is a thin shell around ``route(actionIdentifier:userInfo:)``.
nonisolated enum NotificationRoute: Equatable {
  /// Open the conversation of the memo, with the given input forward.
  case open(ConversationLink)
  /// Speak the memo's reply and open nothing.
  case play(memoID: String)

  static let category = "MEMO_DONE"
  static let replyAction = "MEMO_DONE.reply"
  static let replyByVoiceAction = "MEMO_DONE.replyByVoice"
  static let playAction = "MEMO_DONE.play"

  /// `nil` for a dismissal, an action this app does not know, and a payload without a usable top-level `memo` id.
  static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> NotificationRoute? {
    guard let memoID = memoID(in: userInfo) else { return nil }
    switch actionIdentifier {
    case UNNotificationDefaultActionIdentifier: return .open(ConversationLink(memoID: memoID))
    case replyAction: return .open(ConversationLink(memoID: memoID, focus: .keyboard))
    case replyByVoiceAction: return .open(ConversationLink(memoID: memoID, focus: .voice))
    case playAction: return .play(memoID: memoID)
    default: return nil
    }
  }

  /// The banner of a notification that arrives while the app is open: shown, unless the conversation it belongs to is the
  /// one on screen. The server's `thread-id` is the constant `memo` (it only groups banners), so the memo id is compared with
  /// the memos of the on-screen conversation as well.
  static func presentationOptions(
    for userInfo: [AnyHashable: Any], onScreenThreadID: String?, onScreenMemoIDs: Set<String> = []
  ) -> UNNotificationPresentationOptions {
    let threadID = (userInfo["aps"] as? [AnyHashable: Any])?["thread-id"] as? String
    if let threadID, threadID == onScreenThreadID { return [] }
    if let memoID = memoID(in: userInfo), onScreenMemoIDs.contains(memoID) { return [] }
    return [.banner, .sound]
  }

  private static func memoID(in userInfo: [AnyHashable: Any]) -> String? {
    guard let id = userInfo["memo"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return id
  }
}
