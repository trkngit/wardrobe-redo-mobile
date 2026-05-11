import Foundation

/// Build 8 — lightweight UserDefaults wrapper for the user's most
/// recent occasion pick on each surface.
///
/// Decision recap: build 6 made vibe a real persisted column on
/// `profiles` because the user thinks of it as a stable preference
/// ("I'm a polished person"). Occasion is the opposite — it
/// changes with the user's day, sometimes hour to hour. We don't
/// want it in Postgres (write amplification) but we DO want the
/// app to feel like it remembered.
///
/// Compromise: cache it on-device via UserDefaults. The next app
/// launch lands on the user's last pick instead of always falling
/// back to `.casual`. Cross-device drift is fine — that's the
/// expected behavior of "where I left off on this phone".
///
/// Per-surface keys because the two tabs really are different
/// contexts: someone might pick a "date" outfit on the Outfits
/// tab but be matching a blazer for "work" on the Match tab.
enum OccasionMemory {
    private static let outfitsKey = "wardrobe.lastOccasion.outfits"
    private static let matchKey = "wardrobe.lastOccasion.match"

    // MARK: - Outfits tab

    /// Read the most recent occasion the user picked on the
    /// Outfits tab. Returns `.casual` for the first-ever launch
    /// (no prior write) so the initial UI lands somewhere sensible.
    static func outfitsLastOccasion() -> Occasion {
        readOccasion(forKey: outfitsKey)
    }

    /// Persist the latest pick. Called from the picker `onChange`
    /// after the state mutation lands.
    static func setOutfitsLastOccasion(_ occasion: Occasion) {
        UserDefaults.standard.set(occasion.rawValue, forKey: outfitsKey)
    }

    // MARK: - Match tab

    static func matchLastOccasion() -> Occasion {
        readOccasion(forKey: matchKey)
    }

    static func setMatchLastOccasion(_ occasion: Occasion) {
        UserDefaults.standard.set(occasion.rawValue, forKey: matchKey)
    }

    // MARK: - Helpers

    /// Decode the stored raw value back to an `Occasion`. Defaults
    /// to `.casual` for an absent or unparseable entry — the
    /// engine's "neutral" target that the rest of the app already
    /// uses as the cold-start picker state.
    private static func readOccasion(forKey key: String) -> Occasion {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let occasion = Occasion(rawValue: raw)
        else {
            return .casual
        }
        return occasion
    }
}
