import Foundation
import Supabase

final class SupabaseManager: @unchecked Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              let supabaseURL = URL(string: url) else {
            fatalError("Missing Supabase configuration. Add SUPABASE_URL and SUPABASE_ANON_KEY to Info.plist or Secrets.plist.")
        }

        client = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: key)
    }
}
