import Foundation
import Testing

/// The built bundles carry a German localization: the build wiring (`knownRegions`, the catalogs of the app, the widget extension and
/// IrisUI) is what these prove. The catalogs' content is `scripts/check-strings.ts`'s job.
@Suite("German localization")
struct LocalizationTests {
  /// The `de.lproj` of a bundle, opened as a bundle of its own.
  private func german(_ bundle: Bundle) throws -> Bundle {
    let path = try #require(
      bundle.path(forResource: "de", ofType: "lproj"), "\(bundle.bundleURL.lastPathComponent) has no de.lproj")
    return try #require(Bundle(path: path))
  }

  private func translation(_ key: String, in bundle: Bundle, table: String? = nil) throws -> String {
    try german(bundle).localizedString(forKey: key, value: "<missing>", table: table)
  }

  @Test("The app bundle offers English and German")
  func appLocalizations() {
    #expect(Bundle.main.localizations.contains("de"))
    #expect(Bundle.main.localizations.contains("en"))
  }

  @Test("The app target resolves German")
  func appStrings() throws {
    #expect(try translation("Retry now", in: .main) == "Jetzt wiederholen")
    #expect(try translation("Settings", in: .main) == "Einstellungen")
  }

  @Test("The microphone prompt is localized")
  func microphonePrompt() throws {
    #expect(
      try translation("NSMicrophoneUsageDescription", in: .main, table: "InfoPlist") == "Iris nimmt Sprachmemos auf.")
  }

  @Test("A plural key resolves to a stringsdict entry")
  func pluralDictionary() throws {
    let path = try #require(try german(.main).path(forResource: "Localizable", ofType: "stringsdict"))
    let dictionary = try #require(NSDictionary(contentsOfFile: path))
    #expect(dictionary["%lld segments"] != nil)
  }

  @Test("The widget extension has its own German catalog")
  func widgetStrings() throws {
    let plugIns = try #require(Bundle.main.builtInPlugInsURL)
    let widgets = try #require(Bundle(url: plugIns.appending(path: "IrisWidgets.appex")))
    #expect(try translation("Switch microphone", in: widgets) == "Mikrofon wechseln")
  }

  @Test("IrisUI resolves German from its own bundle")
  func irisUIStrings() throws {
    let url = try #require(Bundle.main.url(forResource: "IrisUI_IrisUI", withExtension: "bundle"))
    let bundle = try #require(Bundle(url: url))
    #expect(try translation("Retry", in: bundle) == "Wiederholen")
  }
}
