import Foundation
import Supabase

@MainActor
final class StyleDataRepository {
    private let supabase = SupabaseManager.shared.client

    // MARK: - Fetch from Supabase (primary) with bundled JSON fallback

    func fetchArchetypes() async -> [StyleArchetype] {
        do {
            let remote: [StyleArchetype] = try await supabase
                .from("style_archetypes")
                .select()
                .execute()
                .value
            if !remote.isEmpty { return remote }
        } catch {
            // Fall through to bundled data
        }
        return loadBundled("archetypes")
    }

    func fetchRules() async -> [StyleRule] {
        do {
            let remote: [StyleRule] = try await supabase
                .from("style_rules")
                .select()
                .execute()
                .value
            if !remote.isEmpty { return remote }
        } catch {
            // Fall through to bundled data
        }
        return loadBundled("rules")
    }

    func fetchArchetypes(forFamily family: String) async -> [StyleArchetype] {
        let all = await fetchArchetypes()
        return all.filter { $0.family == family }
    }

    func fetchRules(forArchetypeId archetypeId: UUID) async -> [StyleRule] {
        let all = await fetchRules()
        return all.filter { $0.archetypeId == archetypeId }
    }

    // MARK: - Bundled JSON Loader

    private func loadBundled<T: Decodable>(_ name: String) -> [T] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "SeedData"),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([T].self, from: data)) ?? []
    }
}
