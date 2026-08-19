import Combine
import Foundation

/// The session-setup selection a player makes before rolling putts — which
/// putter, how long the putt is, and the break — plus their putters for the
/// picker. The selection is applied to a session once the gate creates it (on
/// its first putt); see `GateConnection`.
@MainActor
final class SessionConfigStore: ObservableObject {

    @Published var putters: [Putter] = []
    @Published var selectedPutterId: String?
    @Published var lengthFeet: Int?
    @Published var breakType: String?
    @Published private(set) var loadError: String?

    private let service: SessionMetadataService
    private var cancellables: Set<AnyCancellable> = []

    init(service: SessionMetadataService, auth: AuthManager) {
        self.service = service

        // Reload putters whenever auth becomes ready. The Gate/History views
        // load putters from `.task`, but that first fetch can go out before a
        // valid Firebase ID token is available on a cold start — the request
        // then 401s, the putter list stays empty, and the picker is stuck on
        // "None". Observing auth state re-fetches once the user is signed in
        // (and every subsequent sign-in), so the selection self-heals.
        auth.$state
            .sink { [weak self] state in
                Task { @MainActor in self?.handleAuthState(state) }
            }
            .store(in: &cancellables)
    }

    /// React to an auth transition: load putters once signed in, and drop any
    /// prior user's putters/selection on sign-out.
    private func handleAuthState(_ state: AuthManager.State) {
        switch state {
        case .signedIn:
            Task { await loadPutters() }
        case .signedOut:
            putters = []
            selectedPutterId = nil
        case .loading:
            break
        }
    }

    /// The current selection as session metadata.
    var metadata: SessionMetadata {
        SessionMetadata(
            putterId: selectedPutterId,
            lengthFeet: lengthFeet,
            breakType: breakType
        )
    }

    /// Load the user's putters, defaulting the selection to their active putter
    /// (only when the player hasn't already picked one).
    func loadPutters() async {
        do {
            let loaded = try await service.fetchPutters()
            putters = loaded
            loadError = nil
            if selectedPutterId == nil {
                selectedPutterId = loaded.first(where: { $0.isActive })?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Tag a session with the current selection (after it exists). Best-effort:
    /// the putts are already saved, so a failed tag is non-fatal and ignored.
    func apply(to sessionId: String) async {
        try? await service.apply(sessionId: sessionId, metadata: metadata)
    }
}
