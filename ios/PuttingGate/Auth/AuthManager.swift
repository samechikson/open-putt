import Foundation
import Combine
import FirebaseAuth

/// Observable auth state for the app, backed by Firebase Auth. Firebase persists
/// the session (Keychain) and refreshes ID tokens itself, so this is a thin
/// wrapper: it mirrors Firebase's auth state into `state` and hands out fresh ID
/// tokens for the backend to verify.
@MainActor
final class AuthManager: ObservableObject {

    enum State: Equatable, Sendable {
        case loading      // resolving the persisted session on launch
        case signedOut
        case signedIn(AuthUser)
    }

    @Published private(set) var state: State = .loading

    private var listener: AuthStateDidChangeListenerHandle?

    /// UID of the signed-in user. (The backend derives the owner from the ID
    /// token; this is kept for convenience/telemetry.)
    var userID: String? { Auth.auth().currentUser?.uid }

    init() {
        // Fires immediately with the restored user (or nil), then on every
        // sign-in / sign-out. Firebase invokes this on the main thread; hop
        // through a MainActor Task to satisfy isolation.
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let newState: State = user
                .map { .signedIn(AuthUser(id: $0.uid, email: $0.email)) }
                ?? .signedOut
            Task { @MainActor in self?.state = newState }
        }
    }

    deinit {
        if let listener { Auth.auth().removeStateDidChangeListener(listener) }
    }

    // MARK: - Actions

    func signIn(email: String, password: String) async throws {
        _ = try await Auth.auth().signIn(withEmail: email, password: password)
    }

    /// Create an account. Firebase signs the new user in immediately, so this
    /// always returns true (the Bool is kept for call-site compatibility).
    @discardableResult
    func signUp(email: String, password: String) async throws -> Bool {
        _ = try await Auth.auth().createUser(withEmail: email, password: password)
        return true
    }

    func signOut() async {
        try? Auth.auth().signOut()
    }

    /// Send a password-reset email (needed by users migrated from Supabase, who
    /// must set a new password).
    func resetPassword(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: - Tokens

    /// A currently-valid Firebase ID token (refreshed automatically), or nil
    /// when there's no signed-in user.
    func validAccessToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return try? await user.getIDToken()
    }
}
