import Foundation
import Combine

/// Observable auth state for the app. Owns the current session, persists it to
/// the Keychain, and hands out valid access tokens (refreshing when needed).
@MainActor
final class AuthManager: ObservableObject {

    enum State: Equatable {
        case loading      // restoring a persisted session on launch
        case signedOut
        case signedIn(AuthUser)
    }

    @Published private(set) var state: State = .loading

    private let service = AuthService()
    private var session: AuthSession? {
        didSet { persist() }
    }

    /// User id of the signed-in user, for tagging uploads.
    var userID: String? { session?.user.id }

    init() {
        restore()
    }

    // MARK: - Session lifecycle

    private func restore() {
        guard let data = KeychainStore.load(),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            state = .signedOut
            return
        }
        session = saved
        state = .signedIn(saved.user)
        // Proactively refresh an expired token; sign out if that fails.
        if saved.isExpired {
            Task { await refreshOrSignOut() }
        }
    }

    func signIn(email: String, password: String) async throws {
        let session = try await service.signIn(email: email, password: password)
        self.session = session
        state = .signedIn(session.user)
    }

    /// Returns true if a session was established (confirmation disabled); false
    /// when a confirmation email was sent and the user must confirm first.
    func signUp(email: String, password: String) async throws -> Bool {
        guard let session = try await service.signUp(email: email, password: password) else {
            return false
        }
        self.session = session
        state = .signedIn(session.user)
        return true
    }

    func signOut() async {
        if let token = session?.accessToken {
            await service.signOut(accessToken: token)
        }
        session = nil
        state = .signedOut
    }

    // MARK: - Tokens

    /// A currently-valid access token, refreshing first if it has expired.
    /// Returns nil when there's no session or a refresh fails.
    func validAccessToken() async -> String? {
        guard let current = session else { return nil }
        if !current.isExpired { return current.accessToken }
        await refreshOrSignOut()
        return session?.accessToken
    }

    private func refreshOrSignOut() async {
        guard let refreshToken = session?.refreshToken else { return }
        do {
            let refreshed = try await service.refresh(refreshToken: refreshToken)
            session = refreshed
            state = .signedIn(refreshed.user)
        } catch {
            session = nil
            state = .signedOut
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let session else {
            KeychainStore.clear()
            return
        }
        if let data = try? JSONEncoder().encode(session) {
            KeychainStore.save(data)
        }
    }
}
