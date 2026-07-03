import Foundation
import SwiftUI

/// User-configurable settings, backed by UserDefaults via @AppStorage.
/// Shared as an ObservableObject so capture/upload services can read the
/// latest values without each holding their own @AppStorage.
final class AppSettings: ObservableObject {

    // MARK: Backend

    /// Base URL of the deployed backend on Fly.io. Hardcoded so the app always
    /// talks to production; not user-configurable.
    static let backendBaseURL = "https://putting-gate-backend.fly.dev"

    /// Path appended to the base URL for video uploads. Points at the
    /// multi-putt session analyzer, which persists the session and its putts.
    static let uploadPath = "/analyze-session"

    // MARK: Capture

    /// Capture/record resolution.
    @AppStorage("capturePreset") var capturePresetRaw: String = CapturePreset.hd1080.rawValue

    var capturePreset: CapturePreset {
        get { CapturePreset(rawValue: capturePresetRaw) ?? .hd1080 }
        set { capturePresetRaw = newValue.rawValue }
    }

    /// Resolved upload endpoint on the deployed backend.
    var uploadURL: URL? {
        URL(string: Self.backendBaseURL + Self.uploadPath)
    }
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
