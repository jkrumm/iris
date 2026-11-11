import Foundation
import IrisCore

/// Two conversations for the fake client: one whose answers hold every block type Hermes emits (heading, emphasis,
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
    [chatThread(now: now), hermesThread(now: now), artifactThread(now: now)]
  }

  private static func chatThread(now: Date) -> ThreadDetail {
    let start = now.addingTimeInterval(-200_000)
    let first = Memo(
      id: chatThreadID, mode: .hermes, device: "iphone", startedAt: start, state: .notified, segmentCount: 2,
      audioSeconds: 9.2, transcript: chatQuestion, destinationRef: chatThreadID, replyText: chatReply,
      replyBlocks: [
        ReplyBlock(
          index: 0, width: 320, height: 140,
          svg: SchemeAssets(light: "\(chatThreadID)-svg-light", dark: "\(chatThreadID)-svg-dark"),
          png: SchemeAssets(light: "\(chatThreadID)-png-light", dark: "\(chatThreadID)-png-dark"))
      ],
      summary: MemoSummary(
        headline: "How the step runner retries a failed step",
        detail: "Transient failures are retried twice, then the step fails.", spoken: "Two retries, then failed."),
      threadId: chatThreadID, kind: "chat", actions: ["web"], createdAt: start, updatedAt: start.addingTimeInterval(20))
    let second = Memo(
      id: chatFollowUpID, mode: .hermes, device: "iphone", startedAt: start.addingTimeInterval(120), state: .notified,
      transcript: chatFollowUpQuestion, destinationRef: chatThreadID, replyText: chatFollowUpReply,
      summary: MemoSummary(headline: "Hang guards are not retried", detail: "One window, then retry.", spoken: "No."),
      threadId: chatThreadID, isTyped: true, createdAt: start.addingTimeInterval(120),
      updatedAt: start.addingTimeInterval(131))
    return ThreadDetail(
      thread: MemoThread(
        id: chatThreadID, kind: "hermes", title: "Explain how the step runner retries a failed step, with a diagram",
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
      audioSeconds: 11.0, transcript: "Which Postgres index fits the herd snapshot query?",
      destinationRef: hermesThreadID,
      replyText: "A **partial index** on `(repo, last_activity)` covers it.",
      summary: MemoSummary(
        headline: "A partial index covers the herd query", detail: "Index on repo and last activity.",
        spoken: "A partial index covers it."),
      threadId: hermesThreadID, createdAt: start, updatedAt: start.addingTimeInterval(14))
    let second = Memo(
      id: hermesFollowUpID, mode: .hermes, device: "iphone", startedAt: start.addingTimeInterval(300),
      state: .transcribed, transcript: "Show me the migration for it.", destinationRef: hermesThreadID,
      threadId: hermesThreadID, isTyped: true, createdAt: start.addingTimeInterval(300),
      updatedAt: start.addingTimeInterval(302))
    return ThreadDetail(
      thread: MemoThread(
        id: hermesThreadID, kind: "hermes", title: "Which Postgres index fits the herd snapshot query?",
        createdAt: first.createdAt, updatedAt: second.updatedAt, lastMemoId: second.id),
      memos: [first, second],
      messages: [
        ThreadMessage(memoId: first.id, role: .user, content: first.transcript ?? "", createdAt: first.createdAt),
        ThreadMessage(memoId: first.id, role: .assistant, content: first.replyText ?? "", createdAt: first.updatedAt),
        ThreadMessage(memoId: second.id, role: .user, content: second.transcript ?? "", createdAt: second.createdAt),
      ])
  }

  // MARK: Artifacts

  nonisolated static let artifactThreadID = "e3c2d9f4-6a83-4b5a-9c37-5fa08d4b9e62"
  static let artifactQuestion = "Show me my memo habits as a chart and a table, and write the weekly report."

  nonisolated static let artifactChartSpec =
    #"{"type":"chart","title":"Memos per weekday","kind":"bar","x":["Mon","Tue","Wed","Thu","Fri"],"series":[{"name":"Spoken","values":[4,7,5,6,3]},{"name":"Typed","values":[2,1,3,2,4]}],"unit":"memos"}"#
  nonisolated static let artifactTableSpec =
    #"{"type":"table","title":"Open tasks","columns":["Task","Owner","Done"],"rows":[["Write the spec","Ada",true],["Review the draft","Grace",false]]}"#
  nonisolated static let artifactDocument = """
    # Weekly report

    The week was **calm**: two reviews shipped and the spec is in place.

    - Spoken memos peaked on Tuesday
    - Typed memos peaked on Friday

    ```sh
    make check
    ```
    """

  /// The reply of the artifact thread: a sentence, a chart, a table and a document, in this order.
  static let artifactReply = """
    Here is what the week looked like.

    ```iris-show
    \(artifactChartSpec)
    ```

    ```iris-show
    \(artifactTableSpec)
    ```

    ```iris-doc title="Weekly report" format=markdown
    \(artifactDocument)
    ```
    """

  nonisolated static let artifactChartAssetID = "\(artifactThreadID)-artifact-show-0"
  nonisolated static let artifactTableAssetID = "\(artifactThreadID)-artifact-show-1"
  nonisolated static let artifactDocumentAssetID = "\(artifactThreadID)-artifact-doc-0"

  /// The stored file behind a sample artifact's asset id (what `GET /v1/memos/:id/assets/:assetId` would answer).
  nonisolated static func artifactFile(assetID: String) -> Data? {
    switch assetID {
    case artifactChartAssetID: Data(artifactChartSpec.utf8)
    case artifactTableAssetID: Data(artifactTableSpec.utf8)
    case artifactDocumentAssetID: Data(artifactDocument.utf8)
    default: nil
    }
  }

  static let artifactAssets: [ReplyArtifact] = [
    ReplyArtifact(
      index: 0, kind: .show, title: "Memos per weekday", assetId: artifactChartAssetID,
      bytes: artifactChartSpec.utf8.count),
    ReplyArtifact(
      index: 1, kind: .show, title: "Open tasks", assetId: artifactTableAssetID, bytes: artifactTableSpec.utf8.count),
    ReplyArtifact(
      index: 0, kind: .doc, title: "Weekly report", format: .markdown, assetId: artifactDocumentAssetID,
      bytes: artifactDocument.utf8.count),
  ]

  /// The oldest sample conversation, so History lists it last: one memo whose reply holds a chart, a table and a document.
  private static func artifactThread(now: Date) -> ThreadDetail {
    let start = now.addingTimeInterval(-210_000)
    let memo = Memo(
      id: artifactThreadID, mode: .hermes, device: "iphone", startedAt: start, state: .notified, segmentCount: 1,
      audioSeconds: 6.4, transcript: artifactQuestion, destinationRef: artifactThreadID, replyText: artifactReply,
      replyArtifacts: artifactAssets,
      summary: MemoSummary(
        headline: "A chart, a table and the weekly report", detail: "The week in memos.", spoken: "Here is the week."),
      threadId: artifactThreadID, kind: "chat", actions: ["web"], createdAt: start,
      updatedAt: start.addingTimeInterval(16))
    return ThreadDetail(
      thread: MemoThread(
        id: artifactThreadID, kind: "hermes", title: artifactQuestion, createdAt: memo.createdAt,
        updatedAt: memo.updatedAt, lastMemoId: memo.id),
      memos: [memo],
      messages: [
        ThreadMessage(memoId: memo.id, role: .user, content: artifactQuestion, createdAt: memo.createdAt),
        ThreadMessage(memoId: memo.id, role: .assistant, content: artifactReply, createdAt: memo.updatedAt),
      ])
  }
}
