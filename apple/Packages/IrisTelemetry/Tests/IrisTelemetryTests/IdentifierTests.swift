import Foundation
import Testing

@testable import IrisTelemetry

struct IdentifierTests {
  @Test func traceIDIsTheMemoUUIDLowercasedWithoutDashes() {
    let trace = TraceID(memoID: Fixtures.memoID)
    #expect(trace.hex == "0f8fad5bd9cb469fa16570867728950e")
    #expect(trace.hex.count == 32)
  }

  @Test(arguments: [
    ("0f8fad5bd9cb469fa16570867728950e", true),
    ("0F8FAD5BD9CB469FA16570867728950E", false),
    ("0f8fad5b-d9cb-469f-a165-70867728950e", false),
    ("0f8fad5bd9cb469f", false),
    ("zz8fad5bd9cb469fa16570867728950e", false),
  ])
  func traceIDParsingAcceptsOnlyLowercase32Hex(input: String, valid: Bool) {
    #expect((TraceID(hex: input) != nil) == valid)
  }

  @Test func spanIDIsZeroPaddedSixteenHex() {
    #expect(SpanID(1).hex == "0000000000000001")
    #expect(SpanID(UInt64.max).hex == "ffffffffffffffff")
    #expect(SpanID(hex: "00000000000000ab") == SpanID(0xab))
    #expect(SpanID(hex: "abc") == nil)
  }

  @Test func randomGeneratorProducesDistinctNonZeroIDs() {
    var generator = RandomSpanIDGenerator()
    let ids = (0..<50).map { _ in generator.nextSpanID() }
    #expect(Set(ids).count == 50)
    #expect(!ids.contains(SpanID(0)))
  }
}
