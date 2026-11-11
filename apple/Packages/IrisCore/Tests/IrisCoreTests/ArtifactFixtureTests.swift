import Foundation
import Testing

@testable import IrisCore

/// Every artifact variant of the contract decodes into the type a client renders from: the eight `iris-show` specs and the
/// memo's `replyArtifacts` list (a show spec, a markdown document and an HTML document). `everyFixtureRoundTrips` proves the
/// bytes survive; these prove the values land where the renderer reads them.
@Suite("Artifact fixtures")
struct ArtifactFixtureTests {
  private func spec(_ variant: String) throws -> ShowSpec {
    try IrisJSON.makeDecoder().decode(ShowSpec.self, from: Contracts.fixtureData("artifacts.show-spec.\(variant)"))
  }

  @Test("A table spec keeps its columns and mixed cells, null included")
  func table() throws {
    guard case .table(let table) = try spec("table") else {
      Issue.record("not a table")
      return
    }
    #expect(table.title == "Open tasks")
    #expect(table.columns == ["Task", "Owner", "Done", "Hours"])
    #expect(table.rows.count == 3)
    #expect(table.rows[0] == [.string("Write the spec"), .string("Ada"), .bool(true), .number(3.5)])
    #expect(table.rows[1][3] == .null)
  }

  @Test(
    "Chart specs of every kind decode, gaps stay nil and x keeps strings or numbers",
    arguments: [
      ("chart-bar", ShowSpec.Chart.Kind.bar), ("chart-line", .line), ("chart-area", .area), ("chart-pie", .pie),
    ])
  func chart(_ variant: String, _ kind: ShowSpec.Chart.Kind) throws {
    guard case .chart(let chart) = try spec(variant) else {
      Issue.record("\(variant) is not a chart")
      return
    }
    #expect(chart.kind == kind)
    #expect(chart.series.allSatisfy { $0.values.count == chart.x.count })
  }

  @Test("A bar chart carries its unit and a gap; a line chart has numeric x")
  func chartDetails() throws {
    guard case .chart(let bar) = try spec("chart-bar"), case .chart(let line) = try spec("chart-line") else {
      Issue.record("not charts")
      return
    }
    #expect(bar.unit == "memos")
    #expect(bar.series[1].values == [2, nil, 3])
    #expect(bar.x == [.string("Mon"), .string("Tue"), .string("Wed")])
    #expect(line.title == nil)
    #expect(line.x == [.number(1), .number(2), .number(3), .number(4)])
  }

  @Test("A stat spec keeps numeric and string values, units, deltas and hints")
  func stat() throws {
    guard case .stat(let stat) = try spec("stat") else {
      Issue.record("not a stat")
      return
    }
    #expect(stat.items.map(\.value) == [.number(42), .number(11.2), .string("healthy")])
    #expect(stat.items[1].unit == "s")
    #expect(stat.items[1].delta == -1.4)
    #expect(stat.items[2].delta == nil)
  }

  @Test("A list spec is ordered and an item may have a detail")
  func list() throws {
    guard case .list(let list) = try spec("list") else {
      Issue.record("not a list")
      return
    }
    #expect(list.ordered == true)
    #expect(list.items.map(\.detail) == [nil, "Artifacts render below the text."])
  }

  @Test("A callout spec has its tone and body")
  func callout() throws {
    let decoded = try spec("callout")
    guard case .callout(let callout) = decoded else {
      Issue.record("not a callout")
      return
    }
    #expect(callout.tone == .warning)
    #expect(decoded.title == "Heads up")
  }

  @Test("An unknown spec type is refused")
  func unknownType() {
    let data = Data(#"{"type":"map","title":"x"}"#.utf8)
    #expect(throws: DecodingError.self) { try IrisJSON.makeDecoder().decode(ShowSpec.self, from: data) }
  }

  @Test("`replyArtifacts` lists a show spec and both document formats, indexed per kind")
  func replyArtifacts() throws {
    let detail = try IrisJSON.makeDecoder().decode(
      MemoDetail.self, from: Contracts.fixtureData("memos.detail.response.artifacts"))
    let artifacts = detail.memo.replyArtifacts
    #expect(artifacts.map(\.kind) == [.show, .doc, .doc])
    #expect(artifacts.map(\.index) == [0, 0, 1])
    #expect(artifacts.map(\.format) == [nil, .markdown, .html])
    #expect(artifacts.map(\.title) == ["Woche", "Wochenbericht", nil])
    #expect(artifacts[0].assetId == "b81c4e07-5d29-4a63-9f1e-0c7a3d6e2b48")
    #expect(artifacts[0].bytes == 83)

    let plain = try IrisJSON.makeDecoder().decode(MemoDetail.self, from: Contracts.fixtureData("memos.detail.response"))
    #expect(plain.memo.replyArtifacts.isEmpty)
  }
}
