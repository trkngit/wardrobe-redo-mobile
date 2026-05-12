import Foundation
import Testing
@testable import WardrobeReDo

// MARK: - LanguageManager (build 15)
//
// Verifies the contract the Profile picker depends on: the
// `AppleLanguages` UserDefaults key is the storage, mapping
// to/from `AppLanguage` is bidirectional, and `.system` clears
// the override instead of pinning a value.
//
// `.serialized` because every case reads/writes the same
// `UserDefaults.standard` key. Swift Testing runs cases in
// parallel by default, which races the clear-at-start of one
// test against the set-during another. Serializing keeps the
// 5 cases tractable and adds <100 ms to the suite.

private enum LanguageManagerTestSupport {
    /// Our namespaced preference key. The manager mirrors to
    /// `AppleLanguages` as a side effect, but tests assert against
    /// the namespaced key so they don't have to fight the
    /// system-registered defaults attached to `AppleLanguages`.
    static let preferenceKey = "wardrobe.languagePreference"
    static let appleKey = "AppleLanguages"

    @MainActor
    static func clear() {
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        UserDefaults.standard.removeObject(forKey: appleKey)
    }
}

@Suite(.serialized)
@MainActor
struct LanguageManagerTests {

    @Test func defaultsToSystemWhenUnset() {
        LanguageManagerTestSupport.clear()
        #expect(LanguageManager.current == .system)
    }

    @Test func roundtripsTurkish() {
        LanguageManagerTestSupport.clear()
        defer { LanguageManagerTestSupport.clear() }

        LanguageManager.set(.turkish)
        #expect(LanguageManager.current == .turkish)
    }

    @Test func roundtripsEnglish() {
        LanguageManagerTestSupport.clear()
        defer { LanguageManagerTestSupport.clear() }

        LanguageManager.set(.english)
        #expect(LanguageManager.current == .english)
    }

    @Test func systemClearsOverride() {
        // After pinning a value, setting `.system` removes the
        // override entirely — the next launch should fall back to
        // device language. We verify by reading the UserDefaults
        // key directly to confirm it was removed (not just set to
        // an empty array).
        LanguageManagerTestSupport.clear()
        defer { LanguageManagerTestSupport.clear() }

        LanguageManager.set(.turkish)
        LanguageManager.set(.system)

        #expect(LanguageManager.current == .system)
        #expect(UserDefaults.standard.object(forKey: LanguageManagerTestSupport.preferenceKey) == nil)
    }

    @Test func handlesRegionalSuffixedTags() {
        // The manager prefix-matches "en-US" / "tr-TR" if someone
        // writes a regional code directly to the preference key
        // (e.g. via a future migration). Stored format from our
        // own `set(_:)` is bare ("en" / "tr") so this is mostly
        // a defensive guarantee, not a hot path.
        defer { LanguageManagerTestSupport.clear() }

        UserDefaults.standard.set("en-US", forKey: LanguageManagerTestSupport.preferenceKey)
        #expect(LanguageManager.current == .english)

        UserDefaults.standard.set("tr-TR", forKey: LanguageManagerTestSupport.preferenceKey)
        #expect(LanguageManager.current == .turkish)
    }

    @Test func fallsBackForUnknownTag() {
        // A stored tag we don't surface in the picker (e.g. a future
        // user storing a French preference) should resolve to
        // `.system` so the picker doesn't lie about the current
        // selection.
        defer { LanguageManagerTestSupport.clear() }

        UserDefaults.standard.set("fr", forKey: LanguageManagerTestSupport.preferenceKey)
        #expect(LanguageManager.current == .system)
    }

    @Test func setMirrorsToAppleLanguages() {
        // Setting a non-system value must also write the
        // `AppleLanguages` key — that's what iOS reads at launch.
        // Our own preference key is for the picker's read-back;
        // `AppleLanguages` is what actually swaps the bundle.
        LanguageManagerTestSupport.clear()
        defer { LanguageManagerTestSupport.clear() }

        LanguageManager.set(.turkish)

        #expect(UserDefaults.standard.stringArray(forKey: LanguageManagerTestSupport.appleKey)?.first == "tr")
    }
}
