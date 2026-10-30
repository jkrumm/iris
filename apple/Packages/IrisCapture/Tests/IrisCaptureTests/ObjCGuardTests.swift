import Foundation
import IrisObjCGuard
import Testing

struct ObjCGuardTests {
  @Test func anObjectiveCExceptionBecomesAnErrorInsteadOfAbortingTheProcess() {
    var error: (any Error)?
    do {
      try IrisObjCGuard.perform {
        NSException(name: .invalidArgumentException, reason: "format.sampleRate == hwFormat.sampleRate", userInfo: nil)
          .raise()
      }
    } catch let caught {
      error = caught
    }
    #expect(error?.localizedDescription.contains("hwFormat.sampleRate") == true)
  }

  @Test func aBlockThatDoesNotRaiseRunsOnce() throws {
    var runs = 0
    try IrisObjCGuard.perform { runs += 1 }
    #expect(runs == 1)
  }
}
