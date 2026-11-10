import SwiftUI
import Testing

@testable import IrisUI

struct ArtifactThemeTests {
  private static let required = [
    "--iris-bg", "--iris-panel", "--iris-ink", "--iris-ink-2", "--iris-muted", "--iris-accent", "--iris-border",
    "--iris-status-good", "--iris-status-warn", "--iris-status-bad", "--iris-status-neutral",
    "--iris-radius-card", "--iris-space-md", "--iris-text-sm", "--iris-font-body", "--iris-font-mono", "color-scheme",
  ]

  @Test("Every key is present and non-empty", arguments: [ColorScheme.light, .dark])
  func completeSet(scheme: ColorScheme) {
    let variables = ArtifactTheme.variables(for: scheme)
    for key in Self.required {
      #expect(variables[key]?.isEmpty == false, "\(key) missing in \(scheme)")
    }
    #expect(variables.values.allSatisfy { !$0.isEmpty })
  }

  @Test("Light and dark carry the same keys and differ in color")
  func schemesDiffer() {
    let light = ArtifactTheme.variables(for: .light)
    let dark = ArtifactTheme.variables(for: .dark)
    #expect(Set(light.keys) == Set(dark.keys))
    for key in ["--iris-bg", "--iris-ink", "--iris-accent", "--iris-border", "--iris-status-bad", "color-scheme"] {
      #expect(light[key] != dark[key], "\(key) is the same in both schemes")
    }
    #expect(light["--iris-space-md"] == dark["--iris-space-md"])
  }

  @Test("Colors are rgb() or rgba() with in-range components", arguments: [ColorScheme.light, .dark])
  func colorsParse(scheme: ColorScheme) throws {
    let pattern = try Regex(#"^rgba?\((\d{1,3}), (\d{1,3}), (\d{1,3})(?:, (\d(?:\.\d{1,3})?))?\)$"#)
    let variables = ArtifactTheme.variables(for: scheme)
    let colors = variables.filter { $0.key.hasPrefix("--iris-") && $0.value.hasPrefix("rgb") }
    #expect(colors.count >= 15)
    for (key, value) in colors {
      let match = try #require(value.wholeMatch(of: pattern), "\(key): \(value)")
      for index in 1...3 {
        let component = try #require(match.output[index].substring.flatMap { Int($0) })
        #expect((0...255).contains(component), "\(key): \(value)")
      }
    }
  }

  @Test("Known values")
  func knownValues() {
    let light = ArtifactTheme.variables(for: .light)
    #expect(light["--iris-bg"] == "rgb(242, 242, 245)")
    #expect(light["--iris-divider"] == "rgba(38, 38, 41, 0.09)")
    #expect(light["--iris-radius-card"] == "10px")
    #expect(light["color-scheme"] == "light")
    #expect(ArtifactTheme.variables(for: .dark)["color-scheme"] == "dark")
  }

  @Test("The JSON helper round-trips the variables", arguments: [ColorScheme.light, .dark])
  func json(scheme: ColorScheme) throws {
    let data = Data(ArtifactTheme.json(for: scheme).utf8)
    let decoded = try JSONDecoder().decode([String: String].self, from: data)
    #expect(decoded == ArtifactTheme.variables(for: scheme))
  }
}
