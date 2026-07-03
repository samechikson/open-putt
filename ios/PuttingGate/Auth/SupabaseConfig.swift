import Foundation

/// Public Supabase project config. The URL and anon/publishable key are safe to
/// ship in the client — row-level security governs what the key can do. These
/// match the web frontend's VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY.
enum SupabaseConfig {
    static let url = URL(string: "https://yvwllpouiejwlnsfwsot.supabase.co")!
    static let anonKey = "sb_publishable_NepA34JKud7Cv9VbeTmiOg_dPrH8yXa"

    /// Base URL of the GoTrue auth API.
    static var authURL: URL { url.appendingPathComponent("auth/v1") }
}
