import Foundation

/// Thrown when an auth REST call fails; `message` is safe to show the user.
struct AuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Stateless client for Supabase's GoTrue auth REST API. No third-party SDK —
/// these are the same endpoints supabase-swift calls, driven with URLSession so
/// the app carries no extra dependencies.
struct AuthService {

    /// Sign up with email + password. Returns a session when the project has
    /// email confirmation disabled; returns nil when a confirmation email was
    /// sent instead (no session yet).
    func signUp(email: String, password: String) async throws -> AuthSession? {
        let data = try await post(
            path: "signup",
            body: ["email": email, "password": password]
        )
        // With confirmation on, the response is a user with no access_token.
        return try? decodeSession(data)
    }

    /// Sign in with email + password.
    func signIn(email: String, password: String) async throws -> AuthSession {
        let data = try await post(
            path: "token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": email, "password": password]
        )
        return try decodeSession(data)
    }

    /// Exchange a refresh token for a fresh session.
    func refresh(refreshToken: String) async throws -> AuthSession {
        let data = try await post(
            path: "token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": refreshToken]
        )
        return try decodeSession(data)
    }

    /// Best-effort server-side sign-out; failures are ignored since the client
    /// clears its own session regardless.
    func signOut(accessToken: String) async {
        _ = try? await post(path: "logout", body: [:], accessToken: accessToken)
    }

    // MARK: - Internals

    private func decodeSession(_ data: Data) throws -> AuthSession {
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw AuthError(message: "Unexpected response from auth server")
        }
    }

    private func post(
        path: String,
        query: [URLQueryItem] = [],
        body: [String: String],
        accessToken: String? = nil
    ) async throws -> Data {
        var components = URLComponents(
            url: SupabaseConfig.authURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(accessToken ?? SupabaseConfig.anonKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError(message: "Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "Invalid response from auth server")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(AuthErrorResponse.self, from: data) {
                throw AuthError(message: err.displayMessage)
            }
            throw AuthError(message: "Auth request failed (HTTP \(http.statusCode))")
        }
        return data
    }
}
