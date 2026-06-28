import Foundation
import SwiftData

/// The lifecycle of a clip's upload to the backend.
enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
}

/// A single auto-recorded putt clip stored on disk and uploaded to the backend.
@Model
final class Clip {
    @Attribute(.unique) var id: UUID

    /// Filename (not absolute path) within the app's Documents directory.
    /// Stored relative so it survives container path changes between launches.
    var fileName: String

    var capturedAt: Date
    var duration: Double

    /// Index of this clip within its session (0-based, in capture order).
    var clipIndex: Int

    var uploadStateRaw: String
    var uploadAttempts: Int
    var lastUploadError: String?

    var session: Session?

    init(
        id: UUID = UUID(),
        fileName: String,
        capturedAt: Date = .now,
        duration: Double = 0,
        clipIndex: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.duration = duration
        self.clipIndex = clipIndex
        self.uploadStateRaw = UploadState.pending.rawValue
        self.uploadAttempts = 0
        self.lastUploadError = nil
    }

    var uploadState: UploadState {
        get { UploadState(rawValue: uploadStateRaw) ?? .pending }
        set { uploadStateRaw = newValue.rawValue }
    }

    /// Absolute URL of the clip on disk, resolved against the current
    /// Documents directory.
    var fileURL: URL {
        Clip.clipsDirectory.appendingPathComponent(fileName)
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Directory where clips are stored: <Documents>/Clips.
    static var clipsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
