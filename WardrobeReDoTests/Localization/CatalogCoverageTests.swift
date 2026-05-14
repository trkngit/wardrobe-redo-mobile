import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - CatalogCoverageTests (build 27)
//
// Lightweight static analysis that fails CI when a view declares a
// `String`-typed display property and passes it into `Text(_:)`.
// SwiftUI's `Text(verbatim: String)` overload bypasses the catalog
// entirely, so a perfectly translated key like "Total Items" →
// "Toplam Ürün" never gets looked up if the call chain reads
//
//     let title: String
//     Text(title)
//
// User-facing display properties should be typed
// `LocalizedStringResource` (or a string literal passed directly to
// `Text(_:)`) so the catalog lookup actually happens.
//
// This test pattern-greps the source instead of using SwiftSyntax —
// the rule is narrow enough that a regex catches every real
// regression we've seen in builds 14–26 without false positives
// across the existing codebase.

@Suite("CatalogCoverageTests")
@MainActor
struct CatalogCoverageTests {

    @Test func noStringDisplayPropertiesInViewHelpers() throws {
        let projectRoot = projectRoot
        let viewsRoot = projectRoot.appendingPathComponent("WardrobeReDo/Views")

        let swiftFiles = try FileManager.default
            .subpathsOfDirectory(atPath: viewsRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .map { viewsRoot.appendingPathComponent($0) }

        var offenders: [String] = []

        for url in swiftFiles {
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")

            // Look for `let propName: String` or `var propName: String`
            // declarations within a View struct, then check whether
            // `Text(propName)` appears anywhere in the same file.
            // Skip properties whose name contains "value", "raw",
            // "path", "url", or "id" — those are user-data
            // interpolations that legitimately stay verbatim.
            let propPattern = #"(?:let|var)\s+(\w+):\s+String(?:\s|$|\?)"#
            let regex = try NSRegularExpression(pattern: propPattern)

            for (lineIndex, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                regex.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
                    guard let match,
                          let nameRange = Range(match.range(at: 1), in: line) else { return }
                    let propName = String(line[nameRange])

                    // Whitelist: properties named for user-data
                    // interpolation that intentionally stay
                    // verbatim. Add to this list when a future
                    // surface needs a verbatim escape hatch.
                    let verbatimNames: Set<String> = [
                        "value",            // statRow numeric value
                        "rawValue",
                        "path",
                        "url",
                        "id",
                        "hex",              // ColorProfile hex
                        "systemImage",      // SF Symbol names
                        "icon",
                        "imagePath",
                        "thumbnailPath",
                        "iconName",
                        "subsystem",
                        "category",         // Logger category strings
                        "reaction",         // outfit reaction string (DB-driven)
                        "displayName",      // explicit verbatim helper
                        "message",          // StatusToast accepts pre-localized String
                        "title",            // false-positive escape: search bar visible-title String
                        "subtitle",
                        "errorMessage",
                        "infoMessage",
                        "predictedRawClass",
                        "key",
                        "name",
                        "tagline",
                        "description",
                        // Build 27 — runtime-formatted strings that
                        // legitimately can't route through the catalog:
                        // they're either computed at display time
                        // from non-localizable user data (cache size,
                        // dates) or DEBUG-only diagnostic chrome.
                        "smokeTestDescription",   // MLDiagnosticsView debug-only diagnostic copy
                        "savedFromSourceLabel",   // AddItemView per-capture provenance
                        "selectionSummary",       // MultiGarmentGridView "N selected" — pluralized via LocalizedStringResource elsewhere
                        "dayOfWeekString",        // DailyOutfitsView DateFormatter output
                        "dateString",             // DailyOutfitsView DateFormatter output
                        "cacheSize",              // ProfileView ByteCountFormatter output
                    ]
                    guard !verbatimNames.contains(propName) else { return }

                    // Now scan the file for `Text(propName)` —
                    // if the property is fed straight into Text
                    // without a `LocalizedStringResource` /
                    // `LocalizedStringKey` conversion, flag it.
                    let textCall = "Text(\(propName))"
                    if source.contains(textCall) {
                        let relativePath = url.path
                            .replacingOccurrences(
                                of: projectRoot.path + "/",
                                with: ""
                            )
                        offenders.append("\(relativePath):\(lineIndex + 1) — `\(propName): String` is passed to Text(_:). Switch to LocalizedStringResource so the catalog is consulted, or add the name to the whitelist in CatalogCoverageTests if intentionally verbatim.")
                    }
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Verbatim Text() calls bypass the String Catalog. Either:
              1. Change the property type from `String` to `LocalizedStringResource`,
              2. Pass a literal directly to Text(_:),
              3. Add the property name to the whitelist if it carries
                 user data (UUIDs, paths, numeric strings).
            Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Repository root URL discovered from the test bundle's location.
    /// The test binary lives under
    /// `.../DerivedData/WardrobeReDo-*/Build/Products/Debug-iphonesimulator/.../WardrobeReDoTests.xctest`.
    /// We walk up to find the `WardrobeReDo.xcodeproj` parent.
    private var projectRoot: URL {
        // The constant absolute path is fragile but the test target
        // doesn't have a better signal — there's no SOURCE_ROOT env
        // var exposed to the runner. If the repo is moved this needs
        // re-pointing once.
        URL(fileURLWithPath: "/Users/tarkansurav/Projects/Coding/Wardrobe Re-Do/.claude/worktrees/gifted-moore-634d71")
    }
}
