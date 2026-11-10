#if DEBUG
  import Foundation
  import IrisUI
  import SwiftUI

  /// `-IrisArtifactSpike` shows the artifact island demo instead of the app; `-IrisArtifactIslands <n>` sets how many islands
  /// (default 1). Verification only (`scripts/apple-proof.sh`): screenshots and the WebContent memory per island count.
  enum ArtifactSpike {
    static let argument = "-IrisArtifactSpike"
    static let countArgument = "-IrisArtifactIslands"

    static func islands(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
      guard arguments.contains(argument) else { return nil }
      guard let index = arguments.firstIndex(of: countArgument), arguments.indices.contains(index + 1),
        let count = Int(arguments[index + 1]), count > 0
      else { return 1 }
      return count
    }
  }
#endif
