import Foundation
import Testing

@testable import Iris

@Suite("MetricKit frames")
struct MetricKitFramesTests {
  @Test("the innermost frames of the attributed thread, nearest the fault first")
  func topFrames() throws {
    let json = """
      {"callStacks":[
        {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem","offsetIntoBinaryTextSegment":16,"sampleCount":1}]},
        {"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"dyld","offsetIntoBinaryTextSegment":4096,"sampleCount":1,"subFrames":[
            {"binaryName":"Iris","offsetIntoBinaryTextSegment":255,"sampleCount":1,"subFrames":[
              {"binaryName":"libswiftCore","offsetIntoBinaryTextSegment":4660,"sampleCount":1}]}]}]}]}
      """
    #expect(MetricKitFrames.top(from: Data(json.utf8)) == "libswiftCore+0x1234 < Iris+0xff < dyld+0x1000")
    #expect(MetricKitFrames.top(from: Data(json.utf8), limit: 1) == "libswiftCore+0x1234")
  }

  @Test("garbage is an empty string, not a crash")
  func garbage() {
    #expect(MetricKitFrames.top(from: Data("not json".utf8)).isEmpty)
    #expect(MetricKitFrames.top(from: Data("{}".utf8)).isEmpty)
  }
}
