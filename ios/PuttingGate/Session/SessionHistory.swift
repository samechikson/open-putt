import Foundation

/// One analyzed session, from `GET /api/sessions`. Only the fields the History
/// tab renders are decoded; the backend scopes every row to the signed-in user.
/// Mirrors the frontend `SessionRow` (sessions.ts) and `db.py`'s `_SESSION_COLS`.
struct SessionRow: Codable, Identifiable {
    let id: String
    let createdAt: String
    let capturedAt: String?
    let lengthFeet: Int?
    let breakType: String?
    let puttCount: Int
    let putterId: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case createdAt = "created_at"
        case capturedAt = "captured_at"
        case lengthFeet = "length_feet"
        case breakType = "break_type"
        case puttCount = "putt_count"
        case putterId = "putter_id"
    }

    /// When the putts were struck — the capture time if the device sent one, else
    /// when the row was created.
    var timestamp: Date? {
        SessionRow.parseDate(capturedAt) ?? SessionRow.parseDate(createdAt)
    }

    /// Parses the backend's ISO-8601 timestamps (with or without fractional
    /// seconds; a space or `T` separator).
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: normalized) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: normalized)
    }
}

/// Loads and summarizes the signed-in user's session history for the History
/// tab. Mirrors `SessionConfigStore`: a thin `@MainActor` store over the shared
/// `SessionMetadataService`.
@MainActor
final class SessionHistoryStore: ObservableObject {

    @Published private(set) var sessions: [SessionRow] = []
    /// Mean stored `offset_mm` across all done sessions. Positive = the golfer's
    /// left (a pull); negative = the right (a push) — see `GatePutt.golferSide`.
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
            let doneIds = loaded.filter { $0.status == "done" && $0.puttCount > 0 }.map(\.id)
            if doneIds.isEmpty {
                meanOffsetMm = nil
            } else {
                let offsets = try await service.fetchOffsets(sessionIds: doneIds)
                meanOffsetMm = offsets.isEmpty ? nil : offsets.reduce(0, +) / Double(offsets.count)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
