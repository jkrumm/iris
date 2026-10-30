/// One pending "let this go away after a while" (a toast, a "Copied" confirmation). Arming it again cancels the timer of
/// the earlier value, so a stale timer never clears a newer one; ``cancel()`` is the manual dismissal.
final class ExpiryTimer {
  private var task: Task<Void, Never>?
  private let sleep: @Sendable (Duration) async throws -> Void

  init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

  /// Runs `expire` after `duration` unless the timer is armed again or cancelled first.
  func arm(after duration: Duration, _ expire: @escaping () -> Void) {
    task?.cancel()
    let sleep = sleep
    // Owned here: cancelled by the next `arm`, by ``cancel()`` and when the timer goes away.
    task = Task {
      guard (try? await sleep(duration)) != nil, !Task.isCancelled else { return }
      expire()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  deinit { task?.cancel() }
}
