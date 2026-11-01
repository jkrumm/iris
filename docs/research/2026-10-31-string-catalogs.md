# String catalogs for Iris (Wave 19 R3)

Researched 2026-10-31 (`agw research`, Apple docs + community sources, Xcode 27.1 / Swift 6). Each line is marked
**[verified]** (checked in this repo's build) or **[docs]** (from Apple's documentation, not exercised here).

## Build settings
- `SWIFT_EMIT_LOC_STRINGS=YES` turns on compiler extraction (`.stringsdata`); without it SwiftUI `Text("..")` literals are still found but `String(localized:)`,
  interpolations and `LocalizedStringResource` are not. Xcode sets it only when a catalog is added in the IDE, so a generated project sets it itself. [docs]
- `LOCALIZATION_PREFERS_STRING_CATALOGS=YES` only chooses the export format of a localization export. [docs]
- Both are set for every target in `apple/project.yml`; the build is unchanged otherwise. `xcodebuild` does not rewrite the tracked catalogs. [verified]
- Each app extension is its own bundle: a catalog is a resource of the target that compiles it, so the widget extension needs its own. [verified: `PlugIns/IrisWidgets.appex/de.lproj/Localizable.strings`]
- Xcode 27's localization changes (agent translation, header `NSLocalizedString` extraction, an App Intents fix) leave these semantics as they are. [docs]

## What is localized
- Literals of type `LocalizedStringKey` (`Text`, `Button`, `Label`, `Toggle`, `Picker`, `navigationTitle`, ...), `String(localized:)`, and `LocalizedStringResource`
  literals (App Intent `title` / `description`, `WidgetConfiguration.configurationDisplayName`, `ControlWidgetConfiguration.displayName`) are extracted and looked up. [docs]
- `Text(verbatim:)` and `Text(stringVariable)` are not. A ternary of two literals inside `Text(..)` types as `String` and is not localized; a `comment:` / `bundle:` argument forces
  the localizing initializer. [docs + community; the check treats a bare ternary as an error]
- Live Activity views are ordinary SwiftUI views of the widget extension and read its catalog. [docs]

## Format
- `sourceLanguage`, `strings`, `version`. Per translation `state`: `new`, `translated`, `needs_review`. Staleness is `extractionState: "stale"` (others: `manual`, `migrated`,
  `extracted_with_value`), not a `state`. `shouldTranslate: false` marks source-only strings. [docs]
- Variations: `plural` (CLDR `one` / `other` for German and English) and `device`; they nest. Multiple arguments keep `%@` / `%lld`; a translation that reorders them uses `%1$@`. [docs]
- A literal `%` in a key is written `%%`. [docs; German run on the simulator confirms the key matches, see the PR]

## Bundles
- `String(localized:)` and `Text("..")` default to the main bundle; in a package they need the package bundle: `bundle: #bundle` (Swift 6 macro, used by IrisUI since Wave 16) or `.module`. [verified: IrisUI]
- `LocalizedStringResource` has no `.module` description (`.main`, `.atURL`, `.forClass` only): not needed here, because every `LocalizedStringResource` of Iris lives in an app or widget target. [docs]

## Running in German
- `xcrun simctl launch <udid> com.jkrumm.iris -AppleLanguages "(de)" -AppleLocale de_DE`; the plist-array form `(de)` is required. [docs]
- The built bundle must contain `de.lproj`; that needs `de` in the project's `knownRegions`. XcodeGen derives it from the languages in the catalogs: the generated project lists `Base, de, en`. [verified]
- Info.plist strings: a file named exactly `InfoPlist.xcstrings` in the target, keyed by the raw plist key (`NSMicrophoneUsageDescription`). Built as `de.lproj/InfoPlist.strings`. [verified]
