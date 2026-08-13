import Foundation

/// A center calibration for the hardware gate: the residual per-sensor offset
/// measured by rolling balls dead-center through the gate with the centering jig.
///
/// The firmware already subtracts a baked-in `CENTER_READING[]` (see
/// `putt_tracker.ino`), so every per-sensor value the app receives is a deviation
/// from center that *should* read ~0 for a centered ball. In practice the mount
/// drifts, leaving a small systematic bias. This calibration captures that bias
/// (per sensor) so the app can subtract it from future putts — the same idea as
/// re-measuring `CENTER_READING`, but on the phone and without a reflash.
struct GateCalibration: Codable, Equatable {
    /// The measured center reading per sensor, in the device's mounting order and
    /// the firmware's raw sign (push = positive = the golfer's right). A future
    /// putt's per-sensor offset has this subtracted from it.
    var perSensorBaselineMm: [Double]
    /// How many jig rolls were averaged into the baseline.
    var sampleCount: Int
    var capturedAt: Date
    /// The gate this was captured on (its advertised BLE name), for display.
    var gateName: String?

    /// The aggregate center bias (mean of the per-sensor baselines) — what a
    /// centered putt's average offset was reading before correction.
    var averageBaselineMm: Double {
        guard !perSensorBaselineMm.isEmpty else { return 0 }
        return perSensorBaselineMm.reduce(0, +) / Double(perSensorBaselineMm.count)
    }

    /// |offset| within this band reads as CENTER. Mirrors the firmware's
    /// `DEAD_BAND_MM` so a corrected reading is labeled the same way the device
    /// would have labeled it.
    static let deadBandMm = 2.0

    /// The PUSH / PULL / CENTER label for a (corrected) average offset, using the
    /// same convention and dead band as the firmware's `classify()`.
    static func label(forOffsetMm offset: Double) -> String {
        if offset > deadBandMm { return "PUSH" }
        if offset < -deadBandMm { return "PULL" }
        return "CENTER"
    }

    /// Correct a raw per-sensor reading by subtracting the measured baseline. If
    /// the sensor count doesn't match the baseline (e.g. the firmware's sensor
    /// layout changed), the reading is returned unchanged rather than mis-corrected.
    func correctedSensors(_ raw: [Double?]) -> [Double?] {
        guard raw.count == perSensorBaselineMm.count else { return raw }
        return raw.enumerated().map { index, value in
            value.map { $0 - perSensorBaselineMm[index] }
        }
    }
}
