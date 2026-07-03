import Foundation

/// The authenticated user, as returned by GoTrue.
struct AuthUser: Codable, Equatable {
    let id: String
    let email: String?
}

/// A persisted auth session: the tokens plus the user they belong to. Decoded
/// from the GoTrue token endpoint (snake_case) and stored in the Keychain.
struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry of the access token, in Unix seconds.
    let expiresAt: Double
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case user
    }

    /// True when the access token is expired (or within a 60s safety margin),
    /// so callers know to refresh before using it.
    var isExpired: Bool {
        Date().timeIntervalSince1970 >= (expiresAt - 60)
    }
}

/// Error body GoTrue returns on a failed auth call. Fields vary across versions,
/// so every candidate is optional and `message` picks the first that's present.
struct AuthErrorResponse: Codable {
    let error: String?
    let errorDescription: String?
    let msg: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case msg
        case message
    }

    var displayMessage: String {
        errorDescription ?? message ?? msg ?? error ?? "Authentication failed"
    }
}
