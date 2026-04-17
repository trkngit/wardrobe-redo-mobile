import Foundation
import os
import Supabase
// See UserRepository.swift — `@preconcurrency` unblocks PostgREST's
// Sendable surface on Xcode 16's Swift 6 toolchain.
@preconcurrency import PostgREST

/// Loads style archetypes + rules from Supabase, with bundled JSON as a
/// fallback. The two datasets must stay paired (rule.archetype_id must
/// reference an archetype.id from the SAME source) — otherwise the
/// generation service filters out every archetype and produces zero
/// outfit candidates, surfacing as "Generation timed out or failed."
@MainActor
final class StyleDataRepository {
    private let supabase = SupabaseManager.shared.client
    private let logger = Logger(subsystem: "com.wardroberedo", category: "StyleData")

    /// Cached after first successful load. Both datasets always come from
    /// the same source (remote OR bundled), never mixed.
    private var cached: (archetypes: [StyleArchetype], rules: [StyleRule])?

    // MARK: - Public API

    func fetchArchetypes() async -> [StyleArchetype] {
        await loadPaired().archetypes
    }

    func fetchRules() async -> [StyleRule] {
        await loadPaired().rules
    }

    func fetchArchetypes(forFamily family: String) async -> [StyleArchetype] {
        await loadPaired().archetypes.filter { $0.family == family }
    }

    func fetchRules(forArchetypeId archetypeId: UUID) async -> [StyleRule] {
        await loadPaired().rules.filter { $0.archetypeId == archetypeId }
    }

    // MARK: - Paired Loader

    /// Returns archetypes + rules from a single consistent source. Tries
    /// Supabase first; if either query fails or returns empty, falls back
    /// to bundled JSON for BOTH so the IDs always match.
    private func loadPaired() async -> (archetypes: [StyleArchetype], rules: [StyleRule]) {
        if let cached { return cached }

        // Fetch both from Supabase in parallel. Use only if BOTH are non-empty.
        async let remoteArchetypesTask: [StyleArchetype]? = fetchRemote("style_archetypes")
        async let remoteRulesTask: [StyleRule]? = fetchRemote("style_rules")
        let remoteArchetypes = await remoteArchetypesTask
        let remoteRules = await remoteRulesTask

        if let archetypes = remoteArchetypes, !archetypes.isEmpty,
           let rules = remoteRules, !rules.isEmpty {
            logger.info("Loaded style data from Supabase: \(archetypes.count) archetypes, \(rules.count) rules")
            let result = (archetypes, rules)
            cached = result
            return result
        }

        // One or both empty/failed — fall back to bundled JSON for both so
        // archetype IDs and rule.archetype_id stay consistent.
        let bundledArchetypes: [StyleArchetype] = loadBundled("archetypes")
        let bundledRules: [StyleRule] = loadBundled("rules")
        logger.warning(
            "Falling back to bundled style data (remote archetypes: \(remoteArchetypes?.count ?? -1), remote rules: \(remoteRules?.count ?? -1)). Bundled: \(bundledArchetypes.count) archetypes, \(bundledRules.count) rules."
        )
        let result = (bundledArchetypes, bundledRules)
        cached = result
        return result
    }

    private func fetchRemote<T: Decodable>(_ table: String) async -> [T]? {
        do {
            let rows: [T] = try await supabase
                .from(table)
                .select()
                .execute()
                .value
            return rows
        } catch {
            logger.error("\(table) fetch failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Bundled JSON Loader

    /// Loads `<name>.json` from the app bundle. Tries the bundle root first
    /// (how Xcode bundles loose resource files), then falls back to a
    /// `SeedData/` subdirectory in case the project is reorganized to use a
    /// folder reference. Logs every failure so empty results never go silent.
    private func loadBundled<T: Decodable>(_ name: String) -> [T] {
        let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "SeedData")

        guard let url else {
            logger.error("Bundled JSON not found in app bundle: \(name).json")
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read bundled \(name).json at \(url.path): \(String(describing: error))")
            return []
        }

        // NOTE: do NOT use `.convertFromSnakeCase` here. StyleArchetype and
        // StyleRule declare explicit `CodingKeys` with snake_case rawValues
        // (`editorialName = "editorial_name"`, etc.). Turning on automatic
        // conversion causes the decoder to rename JSON keys to camelCase
        // BEFORE matching against the CodingKey rawValues, which then look
        // for the original snake_case names and fail with
        // `keyNotFound("editorial_name")`. The explicit CodingKeys already
        // handle snake_case — leave the decoder's default strategy.
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            logger.error("Failed to decode bundled \(name).json: \(String(describing: error))")
            return []
        }
    }
}
