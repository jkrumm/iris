import Foundation

/// What History pushes to open a conversation: the thread id, and the title the row already knows so the screen has
/// a name while `GET /v1/threads/:id` is on its way.
struct ThreadRoute: Hashable {
  let id: String
  var title: String?
}
