#if os(iOS)
  import CoreGraphics
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// The thread's building blocks on fixtures that hold every block type, light and dark.
  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct ThreadSnapshotTests {
    static let reply = """
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
        A --> B
      ```

      | State | Meaning | Retried automatically |
      |-|-|-|
      | received | All segments are stored on the server | yes, twice |
      | failed | A step ran out of retries and needs `POST /retry` | no |

      ```swift
      func run(_ step: Step) async throws {
        try await step.run()
      }
      ```

      > A step that already started is never cut off.
      """

    static let asset = MermaidAsset(
      light: ReplyAssetRef(memoID: "m", assetID: "light"), dark: ReplyAssetRef(memoID: "m", assetID: "dark"),
      width: 320, height: 140)

    /// A store that already holds both appearances of the diagram, so the snapshot does not wait for a download.
    static func store() -> ReplyImageStore {
      struct Never: ReplyAssetLoader {
        func data(for ref: ReplyAssetRef) async throws -> Data { throw CancellationError() }
      }
      let store = ReplyImageStore(loader: Never())
      store.seed(diagram(dark: false), for: asset.light)
      store.seed(diagram(dark: true), for: asset.dark)
      return store
    }

    static func diagram(dark: Bool) -> CGImage {
      let context = CGContext(
        data: nil, width: 640, height: 280, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setStrokeColor(dark ? CGColor(gray: 0.9, alpha: 1) : CGColor(gray: 0.1, alpha: 1))
      context.setLineWidth(3)
      for x in [20.0, 240, 460] {
        context.stroke(CGRect(x: x, y: 100, width: 160, height: 80))
      }
      context.move(to: CGPoint(x: 180, y: 140))
      context.addLine(to: CGPoint(x: 240, y: 140))
      context.move(to: CGPoint(x: 400, y: 140))
      context.addLine(to: CGPoint(x: 460, y: 140))
      context.strokePath()
      return context.makeImage()!
    }

    /// English whatever the simulator's language is: the catalog has German, and the references are English.
    private static func assert<Content: View>(
      _ view: Content, width: CGFloat, height: CGFloat, fileID: StaticString = #fileID,
      file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column
    ) {
      SnapshotSupport.assertLightAndDark(
        view.environment(\.locale, Locale(identifier: "en")), width: width, height: height, fileID: fileID,
        file: file, testName: testName, line: line, column: column)
    }

    @Test("a conversation: the question, then the answer with every block type", .tags(.snapshot))
    func conversation() {
      let view = ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
          UserTurnView(text: "Explain how the step runner retries a failed step.", time: "9:41 AM")
          AssistantTurnView(markdown: Self.reply, time: "9:41 AM", mermaid: [0: Self.asset])
        }
        .padding(Theme.Spacing.lg)
      }
      .environment(\.replyImageStore, Self.store())
      Self.assert(view, width: 390, height: 960)
    }

    @Test("an answer that has not arrived shows the step dashes", .tags(.snapshot))
    func pending() {
      let view = VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
        UserTurnView(text: "Show me the migration for it.", time: "9:42 AM")
        PendingTurnView(progress: StepProgress(completed: 2, total: 5), caption: "Asking Hermes…")
      }
      .padding(Theme.Spacing.lg)
      Self.assert(view, width: 390, height: 260)
    }

    @Test("a wide table is a grid, a narrow one turns into cards", .tags(.snapshot))
    func tables() {
      let table = MarkdownTable(
        headers: ["State", "Meaning", "Retried"],
        rows: [["received", "All segments are stored", "yes"], ["failed", "Out of retries", "no"]])
      let view = VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
        MarkdownTableView(table: table)
        MarkdownTableView(table: table).frame(width: 200)
      }
      .padding(Theme.Spacing.lg)
      Self.assert(view, width: 390, height: 520)
    }

    @Test("a diagram that failed to load can be retried", .tags(.snapshot))
    func diagramFailed() {
      let view = MermaidImageView(asset: Self.asset, onOpen: { _ in }).padding(Theme.Spacing.lg)
      Self.assert(view, width: 390, height: 260)
    }

    @Test("the zoomable view of a diagram", .tags(.snapshot))
    func zoomable() {
      let view = ZoomableImageView(image: Self.diagram(dark: false), title: "Diagram", onClose: {})
      Self.assert(view, width: 390, height: 500)
    }
  }
#endif
