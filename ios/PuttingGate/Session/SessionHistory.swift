import Foundation
import FirebaseFirestore

/// One gate session, read from the `sessions` Firestore collection (scoped to the
/// signed-in user by its `user_id` field). Only the fields the History tab renders
/// are kept. Mirrors the web `SessionRow` (sessions.ts) and `db.py`'s
/// `_SESSION_FIELDS`.
struct SessionRow: Identifiable, Hashable {
    let id: String
    /// When the session was created — a gate session is created on its first putt.
    let createdAt: Date?
    let lengthFeet: Int?
    let breakType: String?
    let puttCount: Int
    let putterId: String?

    var timestamp: Date? { createdAt }
}

extension SessionRow {
    init(doc: DocumentSnapshot) {
        id = doc.documentID
        createdAt = (doc.get("created_at") as? Timestamp)?.dateValue()
        lengthFeet = (doc.get("length_feet") as? NSNumber)?.intValue
        breakType = doc.get("break_type") as? String
        puttCount = (doc.get("putt_count") as? NSNumber)?.intValue ?? 0
        putterId = doc.get("putter_id") as? String
    }
}

/// Loads and summarizes the signed-in user's session history for the History
/// tab. Mirrors `SessionConfigStore`: a thin `@MainActor` store over the shared
/// `SessionMetadataService`.
@MainActor
final class SessionHistoryStore: ObservableObject {

    @Published private(set) var sessions: [SessionRow] = []
    /// Mean stored `offset_mm` across all sessions with putts. Positive = the
    /// golfer's left (a pull); negative = the right (a push) — see
    /// `GatePutt.golferSide`.
    @Published private(set) var meanOffsetMm: Double?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let service: SessionMetadataService

    init(service: SessionMetadataService) {
        self.service = service
    }

    var totalPutts: Int { sessions.reduce(0) { $0 + $1.puttCount } }

    func load() async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await service.fetchSessions()
            sessions = loaded
            let ids = loaded.filter { $0.puttCount > 0 }.map(\.id)
            if ids.isEmpty {
                meanOffsetMm = nil
            } else {
                let offsets = try await service.fetchOffsets(sessionIds: ids)
                meanOffsetMm = offsets.isEmpty ? nil : offsets.reduce(0, +) / Double(offsets.count)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
