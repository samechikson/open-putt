import Foundation
import SwiftUI

/// User-configurable settings, backed by UserDefaults via @AppStorage.
/// Shared as an ObservableObject so capture/upload services can read the
/// latest values without each holding their own @AppStorage.
final class AppSettings: ObservableObject {

    // MARK: Backend

    /// Base URL of the backend, e.g. "http://192.168.1.20:8000".
    @AppStorage("backendBaseURL") var backendBaseURL: String = ""

    /// Path appended to the base URL for video uploads. Points at the
    /// multi-putt session analyzer, which persists the session and its putts.
    @AppStorage("uploadPath") var uploadPath: String = "/analyze-session"

    // MARK: Capture

    /// Capture/record resolution.
    @AppStorage("capturePreset") var capturePresetRaw: String = CapturePreset.hd1080.rawValue

    var capturePreset: CapturePreset {
        get { CapturePreset(rawValue: capturePresetRaw) ?? .hd1080 }
        set { capturePresetRaw = newValue.rawValue }
    }

    /// Resolved upload endpoint, or nil if the base URL is not a valid URL.
    var uploadURL: URL? {
        let trimmedBase = backendBaseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedBase.isEmpty,
              var components = URLComponents(string: trimmedBase) else { return nil }
        let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        let path = uploadPath.hasPrefix("/") ? uploadPath : "/" + uploadPath
        components = URLComponents(string: base + path) ?? components
        return components.url
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
