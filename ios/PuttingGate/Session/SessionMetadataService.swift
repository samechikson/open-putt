import Foundation
import FirebaseFirestore
import FirebaseAuth

/// The app's Firestore data layer. iOS reads and writes Firestore **directly**
/// via the Firebase SDK (no backend API): it lists the user's putters/sessions,
/// reads/deletes putts, tags session metadata, and **ingests** hardware-gate
/// putts. Every document carries a `user_id`; `firestore.rules` scopes access to
/// the signed-in user, and each query filters on `user_id` (which also makes the
/// query rule-legal). Ownership-checked writes must keep `user_id == uid`.
///
/// Kept as an `ObservableObject` (it's injected as an environment object), though
/// it publishes nothing itself.
final class SessionMetadataService: ObservableObject {
    private let db = Firestore.firestore()

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The signed-in user's uid, or a thrown error. The app gates all data views
    /// behind auth, so a missing user here is an unexpected state.
    private func uid() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw ServiceError(message: "You're signed out. Sign in and try again.")
        }
        return uid
    }

    // MARK: Reads

    /// The signed-in user's putters (active first, then newest). A single
    /// equality filter (user_id) keeps this index-free; ordering is client-side.
    func fetchPutters() async throws -> [Putter] {
        let uid = try uid()
        let snap = try await db.collection("putters")
            .whereField("user_id", isEqualTo: uid)
            .getDocuments()
        // Single comparator (Swift's sort isn't guaranteed stable): active first,
        // then newest created.
        let sorted = snap.documents.sorted { a, b in
            let aActive = a.get("is_active") as? Bool ?? false
            let bActive = b.get("is_active") as? Bool ?? false
            if aActive != bActive { return aActive }
            let aTime = (a.get("created_at") as? Timestamp)?.dateValue() ?? .distantPast
            let bTime = (b.get("created_at") as? Timestamp)?.dateValue() ?? .distantPast
            return aTime > bTime
        }
        return sorted.map(Putter.init(doc:))
    }

    /// The signed-in user's sessions, newest first.
    func fetchSessions() async throws -> [SessionRow] {
        let uid = try uid()
        let snap = try await db.collection("sessions")
            .whereField("user_id", isEqualTo: uid)
            .getDocuments()
        let sorted = snap.documents.sorted { a, b in
            let aTime = (a.get("created_at") as? Timestamp)?.dateValue() ?? .distantPast
            let bTime = (b.get("created_at") as? Timestamp)?.dateValue() ?? .distantPast
            return aTime > bTime
        }
        return sorted.map(SessionRow.init(doc:))
    }

    /// The putts of one owned session, ordered by putt index. Scoped by user_id
    /// (which also satisfies the security rule for the query).
    func fetchPutts(sessionId: String) async throws -> [SessionPutt] {
        let uid = try uid()
        let snap = try await db.collection("putts")
            .whereField("user_id", isEqualTo: uid)
            .whereField("session_id", isEqualTo: sessionId)
            .getDocuments()
        return snap.documents
            .map(SessionPutt.init(doc:))
            .sorted { $0.puttIndex < $1.puttIndex }
    }

    /// Every putt's `offset_mm` across the given sessions (for the History bias
    /// summary). One user-scoped query, filtered to the requested sessions.
    func fetchOffsets(sessionIds: [String]) async throws -> [Double] {
        if sessionIds.isEmpty { return [] }
        let uid = try uid()
        let wanted = Set(sessionIds)
        let snap = try await db.collection("putts")
            .whereField("user_id", isEqualTo: uid)
            .getDocuments()
        return snap.documents.compactMap { doc in
            guard let sid = doc.get("session_id") as? String, wanted.contains(sid) else {
                return nil
            }
            return (doc.get("offset_mm") as? NSNumber)?.doubleValue
        }
    }

    // MARK: Writes

    /// Tag a session with its metadata (putter / length / break). The session
    /// must already exist (the gate creates it on its first putt). `merge` so the
    /// ownership / created_at / putt_count fields are preserved; a nil field is
    /// written as null to clear it.
    func apply(sessionId: String, metadata: SessionMetadata) async throws {
        _ = try uid()
        try await db.collection("sessions").document(sessionId).setData([
            "length_feet": metadata.lengthFeet.map { $0 as Any } ?? NSNull(),
            "break_type": metadata.breakType.map { $0 as Any } ?? NSNull(),
            "putter_id": metadata.putterId.map { $0 as Any } ?? NSNull(),
        ], merge: true)
    }

    /// Delete one putt from an owned session and keep the session's putt_count in
    /// sync. Deleting a missing doc is a no-op, so this is idempotent.
    func deletePutt(sessionId: String, puttIndex: Int) async throws {
        let uid = try uid()
        try await db.collection("putts")
            .document(Self.puttDocId(sessionId, puttIndex))
            .delete()
        try await updatePuttCount(sessionId: sessionId, uid: uid)
    }

    // MARK: Ingest (hardware gate)

    /// Persist one gate putt: upsert its session (created already-complete on the
    /// first putt) and write the putt. Idempotent per (session, index) via the
    /// deterministic doc id, so a re-send overwrites rather than duplicates.
    ///
    /// The stored sign convention matches the web app and the old backend ingest:
    /// `offset_mm` (and the per-sensor offsets) are **negated** from the firmware
    /// sign, because the display helpers (`golferSide`) negate the stored value to
    /// recover the golfer's left/right. `direction` is derived from the PUSH /
    /// PULL / CENTER label (which carries the firmware sign) and is NOT negated.
    func ingest(_ putt: GatePutt, sessionId: String) async throws {
        let uid = try uid()

        let sessionRef = db.collection("sessions").document(sessionId)
        let sessionSnap = try await sessionRef.getDocument()
        if !sessionSnap.exists {
            try await sessionRef.setData([
                "user_id": uid,
                "status": "done",
                "putt_count": 0,
                "created_at": FieldValue.serverTimestamp(),
            ])
        }

        let storedSensors: [Any] = (putt.sensors ?? []).map { value in
            value.map { -$0 as Any } ?? NSNull()
        }
        try await db.collection("putts")
            .document(Self.puttDocId(sessionId, putt.puttIndex))
            .setData([
                "session_id": sessionId,
                "user_id": uid,
                "putt_index": putt.puttIndex,
                "offset_mm": -putt.offsetMm,
                "direction": Self.direction(for: putt.label),
                "speed_mps": putt.speedMps.map { $0 as Any } ?? NSNull(),
                "sensor_offsets_mm": storedSensors,
            ], merge: true)

        try await updatePuttCount(sessionId: sessionId, uid: uid)
    }

    // MARK: Helpers

    /// Recompute putt_count from the actual putt docs (drift-free under retries).
    private func updatePuttCount(sessionId: String, uid: String) async throws {
        let agg = try await db.collection("putts")
            .whereField("user_id", isEqualTo: uid)
            .whereField("session_id", isEqualTo: sessionId)
            .count
            .getAggregation(source: .server)
        try await db.collection("sessions").document(sessionId).setData(
            ["putt_count": agg.count.intValue], merge: true
        )
    }

    /// Deterministic putt doc id — the per-(session, index) idempotency key.
    private static func puttDocId(_ sessionId: String, _ puttIndex: Int) -> String {
        "\(sessionId)_\(puttIndex)"
    }

    /// Map the gate's PUSH / PULL / CENTER label to the stored side. PUSH (ball
    /// past center, the golfer's right) → "right"; PULL → "left".
    private static func direction(for label: String) -> String {
        switch label.uppercased() {
        case "PUSH": return "right"
        case "PULL": return "left"
        default: return "center"
        }
    }
}
