import Foundation
import SwiftUI

/// User-configurable settings, backed by UserDefaults via @AppStorage.
/// Shared as an ObservableObject so capture/upload services can read the
/// latest values without each holding their own @AppStorage.
final class AppSettings: ObservableObject {

    // MARK: Backend

    /// Base URL of the backend, e.g. "http://192.168.1.20:8000".
    @AppStorage("backendBaseURL") var backendBaseURL: String = ""

    /// Path appended to the base URL for clip uploads.
    @AppStorage("uploadPath") var uploadPath: String = "/upload"

    // MARK: Motion detection

    /// Mean absolute frame difference (0...1) above which motion is triggered.
    /// Lower = more sensitive.
    @AppStorage("motionThreshold") var motionThreshold: Double = 0.04

    /// Seconds after a clip finishes during which new motion is ignored,
    /// so one putt produces exactly one clip.
    @AppStorage("cooldownSeconds") var cooldownSeconds: Double = 1.5

    // MARK: Clip timing

    /// Seconds of footage retained before motion is detected.
    @AppStorage("preRollSeconds") var preRollSeconds: Double = 1.0

    /// Seconds of footage kept recording after motion stops.
    @AppStorage("postRollSeconds") var postRollSeconds: Double = 1.0

    /// Maximum clip length safety cap (seconds), in case motion never settles.
    @AppStorage("maxClipSeconds") var maxClipSeconds: Double = 8.0

    // MARK: Capture

    /// Capture/record resolution. 720p keeps the pre-roll ring buffer light.
    @AppStorage("capturePreset") var capturePresetRaw: String = CapturePreset.hd720.rawValue

    var capturePreset: CapturePreset {
        get { CapturePreset(rawValue: capturePresetRaw) ?? .hd720 }
        set { capturePresetRaw = newValue.rawValue }
    }

    // MARK: Region of interest (normalized 0...1, in the video coordinate space)

    @AppStorage("roiX") var roiX: Double = 0.2
    @AppStorage("roiY") var roiY: Double = 0.2
    @AppStorage("roiWidth") var roiWidth: Double = 0.6
    @AppStorage("roiHeight") var roiHeight: Double = 0.6

    var roi: CGRect {
        CGRect(x: roiX, y: roiY, width: roiWidth, height: roiHeight)
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
