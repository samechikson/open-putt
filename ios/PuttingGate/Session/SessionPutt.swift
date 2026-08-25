import Foundation
import FirebaseFirestore

/// One putt within a session, read from the `putts` Firestore collection. Mirrors
/// the web `PuttRow` (sessions.ts) and `db.py`'s `_PUTT_FIELDS`; only the fields
/// the iOS session-detail view renders are kept.
struct SessionPutt: Identifiable {
    let puttIndex: Int
    let offsetMm: Double?
    let speedMps: Double?
    /// Per-sensor offsets from the hardware gate (mm; null per sensor that
    /// didn't see the ball).
    let sensorOffsetsMm: [Double?]?

    /// The putt_index is the stable per-session identity (a delete leaves a gap
    /// rather than renumbering), so it's a safe list id.
    var id: Int { puttIndex }
}

extension SessionPutt {
    init(doc: DocumentSnapshot) {
        puttIndex = (doc.get("putt_index") as? NSNumber)?.intValue ?? 0
        offsetMm = (doc.get("offset_mm") as? NSNumber)?.doubleValue
        speedMps = (doc.get("speed_mps") as? NSNumber)?.doubleValue
        sensorOffsetsMm = (doc.get("sensor_offsets_mm") as? [Any])?
            .map { ($0 as? NSNumber)?.doubleValue }
    }
}

extension SessionPutt {
    enum Side { case left, right, center }

    /// Golfer's-eye side of the crossing. The stored `offset_mm` is negated from
    /// the firmware/live-view sign when a device putt is ingested (see the
    /// backend's `/device/putts`), so it's negated again here to match how the
    /// live Gate view and the web app (`golferSide`) present left/right.
    var golferSide: Side {
        guard let offset = offsetMm else { return .center }
        let v = -offset
        if v > 0.001 { return .right }
        if v < -0.001 { return .left }
        return .center
    }

    var golferSideLabel: String {
        switch golferSide {
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Center"
        }
    }

    /// Absolute distance off center, in mm.
    var magnitudeMm: Double { abs(offsetMm ?? 0) }
}
