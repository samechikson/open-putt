import Combine
import Foundation

/// One of the user's putters, as returned by `GET /putters`. Mirrors the
/// backend's `_PUTTER_COLS` (only the fields the record screen needs are
/// decoded; the rest of the payload is ignored).
struct Putter: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    /// The user's currently-active putter — at most one per user, enforced by a
    /// partial unique index on the backend. Used as the record screen's default.
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isActive = "is_active"
    }
}

/// Loads the user's putters for the record screen's putter picker.
@MainActor
final class PuttersModel: ObservableObject {

    /// The user's putters, active first then newest (backend ordering).
    @Published private(set) var putters: [Putter] = []

    /// The active putter, which the record screen selects by default.
    var active: Putter? { putters.first(where: \.isActive) }

    /// Fetch the user's putters. Fails soft: on any error the list is left as-is
    /// (the picker just shows what it had, or nothing) — tagging a session with a
    /// putter is optional, so this must never block recording.
    func load(url: URL?, auth: AuthManager) async {
        guard let url else { return }
        var request = URLRequest(url: url)
        if let token = await auth.validAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            putters = try JSONDecoder().decode([Putter].self, from: data)
        } catch {
            // Leave the existing list in place; the picker is optional.
        }
    }
}
