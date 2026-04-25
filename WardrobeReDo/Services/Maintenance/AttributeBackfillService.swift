import Foundation

/// One-shot maintenance service that re-runs `AttributeRulesEngine.derive`
/// on every existing wardrobe item for a user when the rules table has
/// broadened since the item was first saved.
///
/// **Why we need this.** The Outfits tab's occasion subtabs (Casual /
/// Work / Date / Formal / Athletic / Lounge) all showed the same 3
/// outfits in the dogfood window because every item the user added was
/// tagged with `occasions = [.casual]` only — the rules table at the
/// time was overly narrow. Widening the rules in `RulesTable` only
/// affects *new* captures; existing items keep their old narrow tags
/// until backfilled.
///
/// **What "broadened" means.** For each item we compute the seasons +
/// occasions the current rules table produces from
/// `(category, subcategory, texture)`. If the freshly-derived set is
/// **strictly larger** than what's stored on the item we write the
/// new value back. We don't touch items where the stored set is
/// already as wide or wider — that preserves the case where the user
/// manually picked a richer set than rules would have given them.
///
/// **One-shot per user.** `UserDefaults` flag
/// `attribute_backfill_<version>_done_<userId>` gates the work so a
/// reinstall (which clears the defaults) re-runs the backfill once but
/// every-launch in steady state is a no-op. Bump `Self.version` if the
/// rules table widens again and a re-pass is desired.
@MainActor
enum AttributeBackfillService {
    /// Bump this when the rules table broadens enough to justify a
    /// fresh pass for everyone. Embedded in the UserDefaults key so old
    /// completion flags don't suppress the new backfill.
    static let version: Int = 1

    /// Runs the backfill once per user. Cheap when already done — only
    /// reads `UserDefaults` and returns. Intended to be called from
    /// `OutfitViewModel.loadOutfits` so it precedes the Outfits tab's
    /// first fetch and the user immediately sees the broader picks.
    ///
    /// Errors during fetch / update are swallowed — a transient network
    /// failure should not block the Outfits tab from rendering.
    /// Subsequent launches will retry until the flag is set.
    static func runIfNeeded(
        userId: UUID,
        wardrobeRepository: any WardrobeRepositoryProtocol,
        defaults: UserDefaults = .standard
    ) async {
        let key = flagKey(userId: userId)
        guard !defaults.bool(forKey: key) else { return }

        do {
            let items = try await wardrobeRepository.fetchItems(userId: userId)
            for item in items {
                guard let update = computeUpdate(for: item) else { continue }
                _ = try? await wardrobeRepository.updateItem(id: item.id, updates: update)
            }
        } catch {
            // Surface nothing — see doc-comment. Flag stays unset so a
            // future launch retries.
            return
        }

        defaults.set(true, forKey: key)
    }

    /// Pure helper exposed for tests: given a `WardrobeItem`, return
    /// either an update describing the broadened seasons / occasions
    /// to write back, or `nil` if the current values are already as
    /// wide as the rules engine would produce.
    static func computeUpdate(for item: WardrobeItem) -> WardrobeItemUpdate? {
        let derived = AttributeRulesEngine.derive(
            category: item.category,
            subcategory: item.subcategory,
            texture: item.texture
        )

        let storedSeasons = Set(item.seasons)
        let storedOccasions = Set(item.occasions)

        let widerSeasons = derived.seasons.isStrictSuperset(of: storedSeasons)
        let widerOccasions = derived.occasions.isStrictSuperset(of: storedOccasions)
        guard widerSeasons || widerOccasions else { return nil }

        return WardrobeItemUpdate(
            category: nil,
            subcategory: nil,
            texture: nil,
            fitAttribute: nil,
            seasons: widerSeasons
                ? Array(derived.seasons).map(\.rawValue).sorted()
                : nil,
            occasions: widerOccasions
                ? Array(derived.occasions).map(\.rawValue).sorted()
                : nil,
            isArchived: nil
        )
    }

    /// Test seam: flag key is per-user so multiple accounts on the same
    /// device don't collide.
    static func flagKey(userId: UUID) -> String {
        "attribute_backfill_v\(version)_done_\(userId.uuidString)"
    }
}
