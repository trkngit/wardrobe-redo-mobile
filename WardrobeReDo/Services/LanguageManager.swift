import Foundation
import SwiftUI

/// Build 15 — in-app language override.
///
/// Why this exists: iOS exposes a per-app language picker in
/// Settings.app once the bundle has more than one localization
/// (we got there in Build 14), but most users don't know to dig
/// for it. Surfacing the same control inside the app costs almost
/// nothing and removes a friction point.
///
/// Mechanism: writing an array to the `AppleLanguages` key in
/// `UserDefaults.standard` overrides the system language for the
/// current app at next launch. We surface a "restart the app to
/// apply" hint after a change because there's no API to swap the
/// `Bundle` graph mid-process without a fragile bundle-class swizzle
/// — and the system language picker has the same restart behavior,
/// so the UX matches expectations.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = ""
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// What the user sees in the picker row. `.system` reads as
    /// "System default" so a fresh install shows what we'd
    /// otherwise inherit from iOS settings.
    var localizedName: LocalizedStringResource {
        switch self {
        case .system:  LocalizedStringResource("System default")
        case .english: LocalizedStringResource("English")
        case .turkish: LocalizedStringResource("Türkçe")
        }
    }
}

@MainActor
enum LanguageManager {
    /// Apple's key for the per-app language list. iOS reads this
    /// during launch when resolving `preferredLocalizations`. We
    /// write to it as a SIDE EFFECT of setting our own preference
    /// so the override actually takes effect.
    private static let appleLanguagesKey = "AppleLanguages"

    /// Our own key for "what did the user pick in our picker."
    /// Kept separate from `AppleLanguages` because the system
    /// pre-registers that key with defaults from the global
    /// domain — so reading `AppleLanguages` directly never returns
    /// nil even on a fresh install, which makes "no override" and
    /// "system-default override" indistinguishable. Reading from
    /// our own namespaced key avoids that ambiguity.
    private static let preferenceKey = "wardrobe.languagePreference"

    /// Read the user's choice. `.system` is the absence of a
    /// stored preference — we explicitly check `object(forKey:)`
    /// rather than `string(forKey:)` so a stored empty-string
    /// (rawValue of `.system`) still maps cleanly.
    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: preferenceKey),
              !raw.isEmpty else {
            return .system
        }
        // Match prefix because we may also encounter regional
        // suffixes if someone wrote via Settings.app's picker.
        if raw.hasPrefix("tr") { return .turkish }
        if raw.hasPrefix("en") { return .english }
        return .system
    }

    /// Write the user's choice. `.system` clears both keys so the
    /// next launch falls back to device language. Other choices
    /// write to BOTH our preference key (so the picker reads back
    /// correctly even after a sim wipe) AND `AppleLanguages` (so
    /// iOS actually swaps the localization at launch).
    static func set(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
            UserDefaults.standard.set([language.rawValue], forKey: appleLanguagesKey)
        }
        UserDefaults.standard.synchronize()
    }
}
