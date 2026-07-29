import Foundation

/// Relays a putt received over BLE to the backend under the signed-in user's
/// Firebase login. The BLE payload is already the exact `POST /api/device/putts`
/// body, so the raw bytes are forwarded verbatim. Mirrors the small JSON calls
/// in `UploadService` (Bearer token + POST).
final class GatePuttRelay {
    private let settings: AppSettings
    private let auth: AuthManager

    init(settings: AppSettings, auth: AuthManager) {
        self.settings = settings
        self.auth = auth
    }

    struct RelayError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// POST the putt JSON to the backend. Throws on network error or non-2xx.
    func send(_ json: Data) async throws {
        guard let url = settings.devicePuttsURL else {
            throw RelayError(message: "No backend URL configured")
        }
        let token = await auth.validAccessToken()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = json

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayError(message: Self.serverMessage(from: data) ?? "Upload failed")
        }
    }

    /// Human-readable message from a FastAPI error body (`detail` is a string for
    /// HTTPExceptions, an array of `{msg}` for validation errors).
    private static func serverMessage(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        if let detail = json["detail"] as? String { return detail }
        if let items = json["detail"] as? [[String: Any]] {
            let msgs = items.compactMap { $0["msg"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "; ") }
        }
        return nil
    }
}
