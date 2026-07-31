import Foundation

/// Backend calls for session setup: list the user's putters, and tag a session
/// with its metadata (putter / length / break). Mirrors `GatePuttRelay` — a
/// Bearer token from `AuthManager`, URLs from `AppSettings`.
final class SessionMetadataService {
    private let settings: AppSettings
    private let auth: AuthManager

    init(settings: AppSettings, auth: AuthManager) {
        self.settings = settings
        self.auth = auth
    }

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The signed-in user's putters (active first), from `GET /api/putters`.
    func fetchPutters() async throws -> [Putter] {
        guard let url = settings.puttersURL else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
        return try JSONDecoder().decode([Putter].self, from: data)
    }

    /// Tag a session via `PATCH /api/sessions/{id}`. The session must already
    /// exist — the gate creates it on its first putt — so call this only after a
    /// putt of that session has been relayed.
    func apply(sessionId: String, metadata: SessionMetadata) async throws {
        guard let url = settings.sessionURL(id: sessionId) else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: metadata.jsonBody)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw ServiceError(message: serverMessage(from: data) ?? "Request failed")
        }
    }

    /// The `detail` string from a FastAPI error body, if present.
    private static func serverMessage(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return json["detail"] as? String
    }
}
