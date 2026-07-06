import Foundation
import SwiftUI

/// User-configurable settings, backed by UserDefaults via @AppStorage.
/// Shared as an ObservableObject so capture/upload services can read the
/// latest values without each holding their own @AppStorage.
final class AppSettings: ObservableObject {

    // MARK: Backend

    /// Base URL of the deployed backend on Cloud Run. Hardcoded so the app
    /// always talks to production; not user-configurable.
    static let backendBaseURL = "https://putting-gate-backend-tksj5yumxa-uc.a.run.app"

    /// Endpoint that mints a signed Cloud Storage upload URL.
    var uploadsURL: URL? { URL(string: Self.backendBaseURL + "/uploads") }

    /// Endpoint that queues analysis of an already-uploaded object.
    var analyzeSessionURL: URL? { URL(string: Self.backendBaseURL + "/analyze-session") }

    /// Endpoint that pre-flights a single frame: is the gate + ball visible?
    var calibrationCheckURL: URL? { URL(string: Self.backendBaseURL + "/calibration-check") }

    // MARK: Capture

    /// Capture/record resolution.
    @AppStorage("capturePreset") var capturePresetRaw: String = CapturePreset.hd1080.rawValue

    var capturePreset: CapturePreset {
        get { CapturePreset(rawValue: capturePresetRaw) ?? .hd1080 }
        set { capturePresetRaw = newValue.rawValue }
    }

    /// Auto-exposure bias in EV applied while recording. Negative underexposes
    /// (good for bright outdoor scenes); raise it toward 0/positive for dim
    /// indoor light. Clamped to the device's supported range when applied.
    @AppStorage("exposureBias") var exposureBias: Double = -2.0

    /// Selectable exposure steps for the record-screen slider.
    static let exposureBiasRange: ClosedRange<Double> = -3.0...3.0
    static let exposureBiasStep: Double = 0.5
}

/// Subset of AVCaptureSession presets exposed in Settings.
enum CapturePreset: String, CaseIterable, Identifiable {
    case hd720
    case hd1080

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hd720: return "720p (lighter)"
        case .hd1080: return "1080p"
        }
    }
}
