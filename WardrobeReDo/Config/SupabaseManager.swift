import Foundation
import Supabase

final class SupabaseManager: @unchecked Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let url = dict["SUPABASE_URL"] as? String,
              let key = dict["SUPABASE_ANON_KEY"] as? String,
              let supabaseURL = URL(string: url) else {
            fatalError("Missing Supabase configuration. Add Secrets.plist with SUPABASE_URL and SUPABASE_ANON_KEY.")
        }

        client = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: key)
    }
}
