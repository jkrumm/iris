import IrisCore
import Testing
import UserNotifications

@testable import Iris

@Suite("NotificationRoute")
struct NotificationRouteTests {
  private let id = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40"

  private func payload(memo: Any? = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40", threadID: String = "memo") -> [AnyHashable:
    Any]
  {
    var info: [AnyHashable: Any] = ["aps": ["thread-id": threadID, "category": "MEMO_DONE"]]
    if let memo { info["memo"] = memo }
    return info
  }

  @Test("a tap opens the conversation, Reply with the keyboard, Reply by voice with the voice, Play plays")
  func actions() {
    let info = payload()
    #expect(
      NotificationRoute.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info)
        == .open(ConversationLink(memoID: id)))
    #expect(
      NotificationRoute.route(actionIdentifier: NotificationRoute.replyAction, userInfo: info)
        == .open(ConversationLink(memoID: id, focus: .keyboard)))
    #expect(
      NotificationRoute.route(actionIdentifier: NotificationRoute.replyByVoiceAction, userInfo: info)
        == .open(ConversationLink(memoID: id, focus: .voice)))
    #expect(
      NotificationRoute.route(actionIdentifier: NotificationRoute.playAction, userInfo: info) == .play(memoID: id))
  }

  @Test("a dismissal and an unknown action route nowhere")
  func noRoute() {
    #expect(
      NotificationRoute.route(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: payload()) == nil)
    #expect(NotificationRoute.route(actionIdentifier: "SOMETHING_ELSE", userInfo: payload()) == nil)
  }

  @Test("a payload without a usable memo id routes nowhere")
  func badPayload() {
    for memo: Any? in [nil, "", "   ", 42, ["id": "x"]] {
      #expect(
        NotificationRoute.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload(memo: memo))
          == nil)
    }
  }

  @Test("the actions of the category are registered under the identifiers the mapping knows")
  func registeredActions() {
    let ids = [NotificationRoute.replyAction, NotificationRoute.replyByVoiceAction, NotificationRoute.playAction]
    #expect(Set(ids).count == 3)
    #expect(NotificationRoute.category == "MEMO_DONE")
  }

  @Test("a banner shows unless the conversation is the one on screen")
  func presentation() {
    let shown: UNNotificationPresentationOptions = [.banner, .sound]
    #expect(NotificationRoute.presentationOptions(for: payload(), onScreenThreadID: nil) == shown)
    #expect(NotificationRoute.presentationOptions(for: payload(), onScreenThreadID: "other") == shown)
    #expect(
      NotificationRoute.presentationOptions(for: payload(), onScreenThreadID: "other", onScreenMemoIDs: ["x"]) == shown)
    #expect(NotificationRoute.presentationOptions(for: payload(threadID: "t1"), onScreenThreadID: "t1").isEmpty)
    #expect(NotificationRoute.presentationOptions(for: payload(), onScreenThreadID: nil, onScreenMemoIDs: [id]).isEmpty)
    #expect(NotificationRoute.presentationOptions(for: [:], onScreenThreadID: "t1") == shown)
  }
}
