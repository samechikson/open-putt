import Foundation

/// Backend calls for session setup: list the user's putters, and tag a session
/// with its metadata (putter / length / break). Mirrors `GatePuttRelay` — a
/// Bearer token from `AuthManager`, URLs from `AppSettings`.
final class SessionMetadataService: ObservableObject {
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

    /// The signed-in user's sessions, newest first, from `GET /api/sessions`.
    func fetchSessions() async throws -> [SessionRow] {
        guard let url = settings.sessionsURL else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
        return try JSONDecoder().decode([SessionRow].self, from: data)
    }

    /// The putts of one owned session (ordered by putt index), from
    /// `GET /api/sessions/{id}/putts`. Powers the session-detail list.
    func fetchPutts(sessionId: String) async throws -> [SessionPutt] {
        guard let url = settings.sessionPuttsURL(id: sessionId) else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
        return try JSONDecoder().decode([SessionPutt].self, from: data)
    }

    /// Delete one putt from an owned session via
    /// `DELETE /api/sessions/{id}/putts/{index}`. A 404 (the putt is already
    /// gone) counts as success, so the delete is idempotent.
    func deletePutt(sessionId: String, puttIndex: Int) async throws {
        guard let url = settings.puttURL(sessionId: sessionId, puttIndex: puttIndex) else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 404
        else {
            throw ServiceError(message: Self.serverMessage(from: data) ?? "Delete failed")
        }
    }

    /// The `offset_mm` of every putt across the given sessions, from
    /// `POST /api/putts/offsets`. Used for the History push/pull bias summary.
    func fetchOffsets(sessionIds: [String]) async throws -> [Double] {
        guard let url = settings.puttsOffsetsURL else {
            throw ServiceError(message: "No backend URL configured")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await auth.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["session_ids": sessionIds])
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, data)
        struct OffsetsResponse: Decodable { let offsets: [Double] }
        return try JSONDecoder().decode(OffsetsResponse.self, from: data).offsets
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
