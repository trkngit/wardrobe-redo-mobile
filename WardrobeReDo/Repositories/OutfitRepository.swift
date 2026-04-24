import Foundation
import Supabase
// See UserRepository.swift. `@preconcurrency` keeps PostgREST's non-
// Sendable response types crossing actor boundaries under Xcode 16's
// Swift 6 checker; later Xcodes already handle this as a warning.
@preconcurrency import PostgREST

@MainActor
final class OutfitRepository: OutfitRepositoryProtocol {
    private let supabase = SupabaseManager.shared.client
    private let cache: LocalCache

    /// `nonisolated` so non-MainActor callers (`OutfitGenerationService`'s
    /// persistence bridge instantiates `OutfitRepository()` from an
    /// async but non-isolated context) can construct the repo without
    /// hopping to MainActor just for init. The MainActor isolation of
    /// the rest of the class is unaffected.
    nonisolated init(cache: LocalCache = .shared) {
        self.cache = cache
    }

    // MARK: - Fetch by Date (Daily Outfits)

    /// Fetch outfits for a given date with cache-aware fallback.
    /// Write-through on success, cache read on error.
    func fetchOutfitsByDate(userId: UUID, date: String) async throws -> [Outfit] {
        do {
            let outfits: [Outfit] = try await withRetry {
                try await self.supabase
                    .from("outfits")
                    .select()
                    .eq("user_id", value: userId)
                    .eq("date", value: date)
                    .order("score", ascending: false)
                    .execute()
                    .value
            }
            await cache.storeOutfits(outfits, userId: userId, date: date)
            return outfits
        } catch {
            if let cached = await cache.cachedOutfits(userId: userId, date: date) {
                return cached
            }
            throw error
        }
    }

    // MARK: - Fetch History

    /// Fetch recent outfits across all dates.
    func fetchOutfits(userId: UUID, limit: Int = 50) async throws -> [Outfit] {
        try await withRetry {
            try await self.supabase
                .from("outfits")
                .select()
                .eq("user_id", value: userId)
                .order("date", ascending: false)
                .order("score", ascending: false)
                .limit(limit)
                .execute()
                .value
        }
    }

    /// Fetch a single outfit by ID.
    func fetchOutfit(id: UUID) async throws -> Outfit {
        try await withRetry {
            try await self.supabase
                .from("outfits")
                .select()
                .eq("id", value: id)
                .single()
                .execute()
                .value
        }
    }

    // MARK: - Outfit Slots

    /// Fetch all slots for a single outfit.
    func fetchSlots(outfitId: UUID) async throws -> [OutfitSlot] {
        try await withRetry {
            try await self.supabase
                .from("outfit_slots")
                .select()
                .eq("outfit_id", value: outfitId)
                .execute()
                .value
        }
    }

    /// Batch-fetch slots for multiple outfits. Write-through on success
    /// and fall back to cache on error so the daily view still renders
    /// offline.
    func fetchSlotsForOutfits(outfitIds: [UUID]) async throws -> [UUID: [OutfitSlot]] {
        guard !outfitIds.isEmpty else { return [:] }

        do {
            let slots: [OutfitSlot] = try await withRetry {
                try await self.supabase
                    .from("outfit_slots")
                    .select()
                    .in("outfit_id", values: outfitIds)
                    .execute()
                    .value
            }

            let grouped = Dictionary(grouping: slots, by: \.outfitId)
            // Ensure outfits without slots still have a cached empty
            // array so the cache "knows" we fetched them.
            var withEmpties = grouped
            for id in outfitIds where withEmpties[id] == nil {
                withEmpties[id] = []
            }
            await cache.storeSlots(withEmpties)
            return grouped
        } catch {
            if let cached = await cache.cachedSlots(outfitIds: outfitIds) {
                return cached
            }
            throw error
        }
    }

    // MARK: - Insert

    /// Save a generated outfit and its slot assignments.
    /// The outfit ID is client-generated so slots can reference it in a single pass.
    /// If slot insertion fails, the outfit is rolled back (deleted) to prevent orphans.
    ///
    /// Retries are applied per-hop (insert outfit, insert slots) rather
    /// than around the whole sequence — retrying the outer sequence on
    /// a slot failure would try to re-insert the outfit under a fresh
    /// ID and drift from the client-generated `newOutfit.id`. Outfit
    /// inserts carry the client `idempotency_key` (migration 00010)
    /// so a network timeout followed by a retry yields the same row
    /// rather than a duplicate.
    func saveOutfit(_ newOutfit: NewOutfit, slots: [NewOutfitSlot]) async throws -> Outfit {
        let outfit: Outfit = try await withRetry(.interactive) {
            try await self.supabase
                .from("outfits")
                .insert(newOutfit)
                .select()
                .single()
                .execute()
                .value
        }

        if !slots.isEmpty {
            do {
                try await withRetry(.interactive) {
                    try await self.supabase
                        .from("outfit_slots")
                        .insert(slots)
                        .execute()
                }
            } catch {
                // Rollback: delete the orphaned outfit to keep DB consistent.
                // Discard the response explicitly — the `try?` return is an
                // ignorable `Optional<PostgrestResponse<Void>>` under Xcode
                // 16, which emits "result of 'try?' is unused" otherwise.
                _ = try? await supabase
                    .from("outfits")
                    .delete()
                    .eq("id", value: outfit.id)
                    .execute()
                throw error
            }
        }

        // Cached outfits/slots for this user+date are stale now.
        await cache.invalidateOutfits(userId: outfit.userId, date: outfit.date)
        return outfit
    }

    /// Save multiple outfits (daily generation batch).
    func saveDailyOutfits(_ outfits: [(outfit: NewOutfit, slots: [NewOutfitSlot])]) async throws -> [Outfit] {
        var saved: [Outfit] = []
        for (newOutfit, slots) in outfits {
            let outfit = try await saveOutfit(newOutfit, slots: slots)
            saved.append(outfit)
        }
        return saved
    }

    // MARK: - Update Reaction

    /// Save the user's reaction (love/like/skip) to an outfit.
    func updateReaction(outfitId: UUID, reaction: String?) async throws {
        try await withRetry(.interactive) {
            try await self.supabase
                .from("outfits")
                .update(ReactionUpdate(reaction: reaction))
                .eq("id", value: outfitId)
                .execute()
        }
    }

    // MARK: - Mark as Worn

    /// Toggle whether the user wore this outfit.
    func markAsWorn(outfitId: UUID, isWorn: Bool) async throws {
        try await withRetry(.interactive) {
            try await self.supabase
                .from("outfits")
                .update(WornUpdate(isWorn: isWorn))
                .eq("id", value: outfitId)
                .execute()
        }
    }

    // MARK: - Delete

    /// Delete an outfit. Slots are cascade-deleted by the database.
    func deleteOutfit(id: UUID) async throws {
        try await withRetry {
            try await self.supabase
                .from("outfits")
                .delete()
                .eq("id", value: id)
                .execute()
        }
    }

    // MARK: - Recent Item Tracking

    /// Fetch wardrobe item IDs worn in the last N days.
    /// Used by VersatilityScorer to penalize recently-worn items.
    func fetchRecentItemIds(userId: UUID, days: Int = 7) async throws -> Set<UUID> {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = formatter.string(from: cutoff)

        let recentOutfits: [Outfit] = try await supabase
            .from("outfits")
            .select()
            .eq("user_id", value: userId)
            .eq("is_worn", value: true)
            .gte("date", value: cutoffString)
            .execute()
            .value

        guard !recentOutfits.isEmpty else { return [] }

        let slotsByOutfit = try await fetchSlotsForOutfits(outfitIds: recentOutfits.map(\.id))
        return Set(slotsByOutfit.values.flatMap { $0 }.map(\.wardrobeItemId))
    }

    // MARK: - Existence Check

    /// Check whether outfits have already been generated for a given date.
    func hasOutfitsForDate(userId: UUID, date: String) async throws -> Bool {
        let outfits: [Outfit] = try await supabase
            .from("outfits")
            .select()
            .eq("user_id", value: userId)
            .eq("date", value: date)
            .limit(1)
            .execute()
            .value
        return !outfits.isEmpty
    }

    // MARK: - Date Helper

    /// Today's date formatted as a Supabase DATE string (yyyy-MM-dd).
    nonisolated static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

// MARK: - Insert DTOs

struct NewOutfit: Codable, Sendable {
    let id: UUID
    let userId: UUID
    let archetypeId: UUID
    let editorialName: String
    let editorialDescription: String?
    let date: String
    let score: Double
    let scoreBreakdown: ScoreBreakdown?
    let isWorn: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case archetypeId = "archetype_id"
        case editorialName = "editorial_name"
        case editorialDescription = "editorial_description"
        case date, score
        case scoreBreakdown = "score_breakdown"
        case isWorn = "is_worn"
    }
}

struct NewOutfitSlot: Codable, Sendable {
    let outfitId: UUID
    let wardrobeItemId: UUID
    let slotName: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case outfitId = "outfit_id"
        case wardrobeItemId = "wardrobe_item_id"
        case slotName = "slot_name"
        case role
    }
}

// MARK: - Update DTOs

private struct ReactionUpdate: Codable, Sendable {
    let reaction: String?
}

private struct WornUpdate: Codable, Sendable {
    let isWorn: Bool

    enum CodingKeys: String, CodingKey {
        case isWorn = "is_worn"
    }
}
