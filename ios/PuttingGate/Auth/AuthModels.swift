import Foundation

/// The authenticated user (Firebase UID + email). Tokens and session
/// persistence are handled by the Firebase Auth SDK, so nothing else is stored
/// here.
struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    let email: String?
}
