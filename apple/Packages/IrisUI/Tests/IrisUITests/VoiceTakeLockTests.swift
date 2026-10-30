import Testing

@testable import IrisUI

struct VoiceTakeLockTests {
  @Test("a lock request becomes a locked take once the take is running")
  func locksWhenRunning() {
    var lock = VoiceTakeLock()
    lock.request()
    #expect(!lock.isLocked)
    lock.takeChanged(isRecording: true)
    #expect(lock.isLocked)
    lock.takeChanged(isRecording: false)
    #expect(!lock.isLocked)
  }

  @Test("a locked take that failed to start does not lock the next take")
  func failedStartIsForgotten() {
    var lock = VoiceTakeLock()
    lock.request()  // the take never reports running
    lock.beginUnlocked()  // the next take starts by a hold or the VoiceOver action
    lock.takeChanged(isRecording: true)
    #expect(!lock.isLocked)
  }

  @Test("a take that ends clears the lock and the request with it")
  func endClears() {
    var lock = VoiceTakeLock()
    lock.request()
    lock.takeChanged(isRecording: true)
    lock.takeChanged(isRecording: false)
    lock.takeChanged(isRecording: true)
    #expect(!lock.isLocked)
  }
}
