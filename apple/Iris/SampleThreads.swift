import Foundation
import IrisCore

/// Two conversations for the fake client: a chat whose answers hold every block type Hermes emits (heading, emphasis,
/// links, lists, code, table, quote, Mermaid), and a Hermes thread whose second turn is still in the pipeline. Their
/// ids are fixed so UI tests and snapshots can name them.
extension SampleData {
  static let chatThreadID = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40"
  static let chatFollowUpID = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c41"
  static let hermesThreadID = "d2b1c8e3-5f72-4a49-8b26-4e9f7c3a8d51"
  static let hermesFollowUpID = "d2b1c8e3-5f72-4a49-8b26-4e9f7c3a8d52"

  /// The question that opens the chat thread; History shows it as the row.
  static let chatQuestion = "Explain how the step runner retries a failed step, with a diagram and the states."

  /// Every block type in one reply.
  static let chatReply = """
    ## Retry model

    The runner retries **transient** failures twice, after *2 s* and *8 s*, and then marks the step `failed`. The \
    [design doc](https://example.com/tdd) has the full rules.

    1. Run the step handler
    2. On a `TransientError`, wait and run it again
    3. After the second retry, fail the step

    - Bookkeeping errors are not step failures
    - A retry from `act` types the transcript again

    ```mermaid
    graph LR
      A[Handler] --> B{Transient?}
      B -->|yes| C[Retry]
      B -->|no| D[Fail]
    ```

    | State | Meaning | Retried automatically |
    |-|-|-|
    | received | All segments are stored on the server | yes, twice |
    | transcribed | The text is ready and waits for a route | yes, twice |
    | failed | A step ran out of retries and needs `POST /retry` | no |

    ```swift
    func run(_ step: Step) async throws {
      for delay in [2.0, 8.0] {
        do { return try await step.run() } catch is TransientError { try await Task.sleep(for: .seconds(delay)) }
      }
      try await step.run()
    }
    ```

    > A step that already started is never cut off; only the wait before it is bounded.
    """

  static let chatFollowUpQuestion = "And a hang guard, is that retried too?"
  static let chatFollowUpReply =
    "No. A hang guard is a **plain error**: one window, then `POST /retry` starts it again."

  static func threadDetails(now: Date = Date()) -> [ThreadDetail] {
    [chatThread(now: now), hermesThread(now: now)]
  }

  private static func chatThread(now: Date) -> ThreadDetail {
    let start = now.addingTimeInterval(-200_000)
    let first = Memo(
      id: chatThreadID, mode: .chat, device: "iphone", startedAt: start, state: .notified, segmentCount: 2,
      audioSeconds: 9.2, transcript: chatQuestion, route: "hermes", destinationRef: chatThreadID,
      replyText: chatReply,
      replyBlocks: [
        ReplyBlock(
          index: 0, width: 320, height: 140,
          svg: SchemeAssets(light: "\(chatThreadID)-svg-light", dark: "\(chatThreadID)-svg-dark"),
          png: SchemeAssets(light: "\(chatThreadID)-png-light", dark: "\(chatThreadID)-png-dark"))
      ],
      summary: MemoSummary(
        headline: "How the step runner retries a failed step",
        detail: "Transient failures are retried twice, then the step fails.", spoken: "Two retries, then failed."),
      threadId: chatThreadID, createdAt: start, updatedAt: start.addingTimeInterval(20))
    let second = Memo(
      id: chatFollowUpID, mode: .chat, device: "iphone", startedAt: start.addingTimeInterval(120), state: .notified,
      transcript: chatFollowUpQuestion, route: "hermes", destinationRef: chatThreadID, replyText: chatFollowUpReply,
      summary: MemoSummary(headline: "Hang guards are not retried", detail: "One window, then retry.", spoken: "No."),
      threadId: chatThreadID, isTyped: true, createdAt: start.addingTimeInterval(120),
      updatedAt: start.addingTimeInterval(131))
    return ThreadDetail(
      thread: MemoThread(
        id: chatThreadID, kind: .chat, title: "Explain how the step runner retries a failed step, with a diagram",
        createdAt: first.createdAt, updatedAt: second.updatedAt, lastMemoId: second.id),
      memos: [first, second],
      messages: [
        ThreadMessage(memoId: first.id, role: .user, content: chatQuestion, createdAt: first.createdAt),
        ThreadMessage(memoId: first.id, role: .assistant, content: chatReply, createdAt: first.updatedAt),
        ThreadMessage(memoId: second.id, role: .user, content: chatFollowUpQuestion, createdAt: second.createdAt),
        ThreadMessage(memoId: second.id, role: .assistant, content: chatFollowUpReply, createdAt: second.updatedAt),
      ])
  }

  private static func hermesThread(now: Date) -> ThreadDetail {
    let start = now.addingTimeInterval(-180_000)
    let first = Memo(
      id: hermesThreadID, mode: .hermes, device: "iphone", startedAt: start, state: .notified, segmentCount: 2,
      audioSeconds: 11.0, transcript: "Which Postgres index fits the herd snapshot query?", route: "hermes",
      destinationRef: hermesThreadID,
      replyText: "A **partial index** on `(repo, last_activity)` covers it.",
      summary: MemoSummary(
        headline: "A partial index covers the herd query", detail: "Index on repo and last activity.",
        spoken: "A partial index covers it."),
      threadId: hermesThreadID, createdAt: start, updatedAt: start.addingTimeInterval(14))
    let second = Memo(
      id: hermesFollowUpID, mode: .hermes, device: "iphone", startedAt: start.addingTimeInterval(300),
      state: .routed, transcript: "Show me the migration for it.", route: "hermes", destinationRef: hermesThreadID,
      threadId: hermesThreadID, isTyped: true, createdAt: start.addingTimeInterval(300),
      updatedAt: start.addingTimeInterval(302))
    return ThreadDetail(
      thread: MemoThread(
        id: hermesThreadID, kind: .hermes, title: "Which Postgres index fits the herd snapshot query?",
        createdAt: first.createdAt, updatedAt: second.updatedAt, lastMemoId: second.id),
      memos: [first, second],
      messages: [
        ThreadMessage(memoId: first.id, role: .user, content: first.transcript ?? "", createdAt: first.createdAt),
        ThreadMessage(memoId: first.id, role: .assistant, content: first.replyText ?? "", createdAt: first.updatedAt),
        ThreadMessage(memoId: second.id, role: .user, content: second.transcript ?? "", createdAt: second.createdAt),
      ])
  }
}
