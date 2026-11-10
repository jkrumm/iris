/// What an artifact island shows.
public enum ArtifactEntry: Sendable, Hashable {
  /// A page bundled with IrisUI: the file name under `Resources/Artifact`, e.g. `island.html`. It may run its own bundled scripts.
  case bundled(String)
  /// A generated document. It is served with a CSP that forbids scripts, so it only ever renders.
  case html(String)
}
