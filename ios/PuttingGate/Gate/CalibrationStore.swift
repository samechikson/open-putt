import Foundation

/// Holds the active center calibration and drives the calibration capture flow.
///
/// Two roles: (1) the persisted `active` calibration that `GateConnection`
/// applies to every incoming putt, and (2) the live state of a capture in
/// progress — while `isCalibrating`, the gate routes jig rolls here (via
/// `record`) instead of relaying them as putts. Persisted to `UserDefaults` as a
/// small JSON blob so a calibration survives relaunches.
///
/// Not `@MainActor`: like `GateConnection`, its `@Published` state is mutated
/// only from the main thread — the BLE delegate (which runs on the main queue)
/// and SwiftUI actions — so it stays a plain `ObservableObject` the gate can
/// read synchronously.
final class CalibrationStore: ObservableObject {

    /// The calibration currently applied to putts, or nil if uncalibrated.
    @Published private(set) var active: GateCalibration?

    // Capture-in-progress state (only meaningful while `isCalibrating`).
    @Published private(set) var isCalibrating = false
    @Published private(set) var sampleCount = 0
    /// The running per-sensor mean of the rolls captured so far — a live preview
    /// of the baseline that `finish()` would commit.
    @Published private(set) var liveBaselineMm: [Double] = []
    /// The most recent jig roll's raw per-sensor offsets, for a live readout.
    @Published private(set) var lastRollMm: [Double]?

    private var sums: [Double] = []
    private let defaults: UserDefaults
    private static let storageKey = "gateCalibration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Capture flow

    /// Start a fresh capture, discarding any rolls collected in a prior attempt.
    /// Does not touch the active calibration until `finish()`.
    func begin() {
        isCalibrating = true
        sampleCount = 0
        sums = []
        liveBaselineMm = []
        lastRollMm = nil
    }

    /// Fold one centered jig roll into the running baseline. `sensors` are the
    /// raw per-sensor offsets (all present — callers pass complete readings only).
    func record(sensors: [Double]) {
        guard !sensors.isEmpty else { return }
        if sums.count != sensors.count {
            // First roll (or a sensor-count change): (re)start the accumulator.
            sums = Array(repeating: 0, count: sensors.count)
            sampleCount = 0
        }
        for i in sensors.indices { sums[i] += sensors[i] }
        sampleCount += 1
        liveBaselineMm = sums.map { $0 / Double(sampleCount) }
        lastRollMm = sensors
    }

    /// Commit the captured rolls as the active calibration and stop capturing.
    /// No-op if nothing was captured.
    func finish(gateName: String?) {
        guard sampleCount > 0, !liveBaselineMm.isEmpty else { return }
        active = GateCalibration(
            perSensorBaselineMm: liveBaselineMm,
            sampleCount: sampleCount,
            capturedAt: Date(),
            gateName: gateName
        )
        persist()
        isCalibrating = false
    }

    /// Abandon a capture in progress, leaving the active calibration untouched.
    func cancel() {
        isCalibrating = false
        sampleCount = 0
        sums = []
        liveBaselineMm = []
        lastRollMm = nil
    }

    /// Remove the active calibration; future putts are relayed uncorrected.
    func clear() {
        active = nil
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: Persistence

    private func persist() {
        guard let active, let data = try? JSONEncoder().encode(active) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(GateCalibration.self, from: data)
        else { return }
        active = stored
    }
}
