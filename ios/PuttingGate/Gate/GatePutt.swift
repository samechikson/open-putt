import Foundation

/// One putt received from the hardware gate over BLE. Decodes the JSON the
/// firmware sends; the app applies any center calibration, then writes it to
/// Firestore (see `SessionMetadataService.ingest`).
struct GatePutt: Codable, Identifiable {
    let sessionID: String
    let puttIndex: Int
    let offsetMm: Double
    let label: String
    let speedMps: Double?
    /// Per-sensor offsets (mm), device order; a sensor that didn't see the ball
    /// is null. Diagnostic — the backend also stores these.
    let sensors: [Double?]?

    /// Stable id within a session (session + index), matching the backend's
    /// idempotency key.
    var id: String { "\(sessionID)-\(puttIndex)" }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case puttIndex = "putt_index"
        case offsetMm = "offset_mm"
        case label
        case speedMps = "speed_mps"
        case sensors
    }
}

extension GatePutt {
    enum Side { case left, right, center }

    /// Golfer's-eye side of the crossing. The device reports the raw firmware
    /// offset (push = positive = the golfer's right). Display that sign directly:
    /// the backend negates the value on ingest and the web app's `golferSide`
    /// negates it again for display, so those two cancel and the web ends up
    /// showing this same raw sign — the phone must match it, not re-invert.
    var golferSide: Side {
        if offsetMm > 0.001 { return .right }
        if offsetMm < -0.001 { return .left }
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
    var magnitudeMm: Double { abs(offsetMm) }

    /// Whether every sensor saw the ball. A real putt rolls over all the in-line
    /// sensors in sequence, so a complete `sensors` array (no missing readings)
    /// is the mark of a genuine putt; a partial reading is almost always an
    /// errant trip (e.g. sunlight outdoors) and is ignored. Mirrors the firmware
    /// guard (the ingest also drops partial readings before they're stored).
    var hasAllSensors: Bool {
        guard let sensors, !sensors.isEmpty else { return false }
        return !sensors.contains(where: { $0 == nil })
    }

    /// A copy of this putt with a center calibration applied: each per-sensor
    /// offset has its measured baseline subtracted, the average offset is
    /// recomputed from the corrected sensors, and the label is re-derived so it
    /// stays consistent with the corrected value. Returns an unchanged copy if
    /// there are no sensors to correct.
    func applying(_ calibration: GateCalibration) -> GatePutt {
        guard let sensors else { return self }
        let corrected = calibration.correctedSensors(sensors)
        let present = corrected.compactMap { $0 }
        let avg = present.isEmpty
            ? offsetMm
            : present.reduce(0, +) / Double(present.count)
        return GatePutt(
            sessionID: sessionID,
            puttIndex: puttIndex,
            offsetMm: avg,
            label: GateCalibration.label(forOffsetMm: avg),
            speedMps: speedMps,
            sensors: corrected
        )
    }
}
