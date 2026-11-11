#if DEBUG
  import Foundation
  import IrisCore
  import IrisUI
  import SwiftUI

  /// `-IrisArtifactSample cards|viewer` shows the sample artifact reply (a chart card, a table card and a document card) or the
  /// viewer on the sample document instead of the app. Verification only (`scripts/apple-proof.sh`, `-IrisMacSnapshot`): both
  /// read the fake media source, so no server is involved.
  enum ArtifactSample: String {
    case cards
    case viewer

    static let argument = "-IrisArtifactSample"

    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> ArtifactSample? {
      guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
      return ArtifactSample(rawValue: arguments[index + 1])
    }
  }

  struct ArtifactSampleScreen: View {
    let sample: ArtifactSample
    /// `false` lays the cards out without a scroll view: the Mac capture draws the view itself, which skips a scroll view's content.
    var scrolls = true
    @State private var store = ArtifactStore(
      loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
    @State private var budget = ArtifactIslandBudget()

    private var memo: Memo? {
      SampleData.threadDetails().flatMap(\.memos).first { $0.id == SampleData.artifactThreadID }
    }

    var body: some View {
      Group {
        switch sample {
        case .cards: cards
        case .viewer: viewer
        }
      }
      .environment(\.artifactStore, store)
      .environment(\.artifactIslandBudget, budget)
      .background(Theme.Surface.background)
    }

    @ViewBuilder private var cards: some View {
      let turn = AssistantTurnView(
        markdown: SampleData.artifactReply, time: "09:42", artifacts: memo?.artifactAssets ?? [:]
      )
      .padding(.horizontal, Theme.Spacing.screenMargin)
      .padding(.vertical, Theme.Spacing.lg)
      if scrolls {
        ScrollView { turn }
      } else {
        turn.frame(maxHeight: .infinity, alignment: .top)
      }
    }

    @ViewBuilder private var viewer: some View {
      if let asset = memo?.artifactAssets[ArtifactAsset.Key(kind: .doc, index: 0)] {
        ArtifactViewer(request: ArtifactViewerRequest(asset: asset, source: SampleData.artifactDocument))
      }
    }
  }
#endif
