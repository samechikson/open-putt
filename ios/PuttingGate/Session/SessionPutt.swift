import Foundation

/// One putt within a session, from `GET /api/sessions/{id}/putts`. Mirrors the
/// web `PuttRow` (sessions.ts) and `db.py`'s `_PUTT_COLS`; only the fields the
/// iOS session-detail view renders are decoded.
struct SessionPutt: Codable, Identifiable {
    let puttIndex: Int
    let offsetMm: Double?
    let speedMps: Double?
    /// Per-sensor offsets from a hardware-gate putt (mm; null per sensor that
    /// didn't see the ball, null entirely for video-pipeline putts).
    let sensorOffsetsMm: [Double?]?

    /// The putt_index is the stable per-session identity (a delete leaves a gap
    /// rather than renumbering), so it's a safe list id.
    var id: Int { puttIndex }

    enum CodingKeys: String, CodingKey {
        case puttIndex = "putt_index"
        case offsetMm = "offset_mm"
        case speedMps = "speed_mps"
        case sensorOffsetsMm = "sensor_offsets_mm"
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
