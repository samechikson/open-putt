import Foundation
import SwiftData

/// The lifecycle of a recording's upload to the backend.
enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
}

/// A single video recorded by the user and uploaded to the backend for
/// processing. The app itself does no analysis — it just records and sends.
@Model
final class Recording {
    @Attribute(.unique) var id: UUID

    /// Filename (not absolute path) within the app's Recordings directory.
    /// Stored relative so it survives container path changes between launches.
    var fileName: String

    var capturedAt: Date
    var duration: Double

    /// User-entered length of the putt, in feet.
    var lengthFeet: Int = 9
    /// User-selected slope + break direction (raw value of `PuttBreak`).
    var breakTypeRaw: String = PuttBreak.straight.rawValue
    /// The putter used, as the backend putter's UUID string. Optional: a session
    /// can be untagged (no putters set up, or none selected).
    var putterID: String?

    var uploadStateRaw: String
    var uploadAttempts: Int
    var lastUploadError: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        capturedAt: Date = .now,
        duration: Double = 0,
        lengthFeet: Int = 9,
        breakType: PuttBreak = .straight,
        putterID: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.duration = duration
        self.lengthFeet = lengthFeet
        self.breakTypeRaw = breakType.rawValue
        self.putterID = putterID
        self.uploadStateRaw = UploadState.pending.rawValue
        self.uploadAttempts = 0
        self.lastUploadError = nil
    }

    var uploadState: UploadState {
        get { UploadState(rawValue: uploadStateRaw) ?? .pending }
        set { uploadStateRaw = newValue.rawValue }
    }

    var breakType: PuttBreak {
        get { PuttBreak(rawValue: breakTypeRaw) ?? .straight }
        set { breakTypeRaw = newValue.rawValue }
    }

    /// Absolute URL of the recording on disk, resolved against the current
    /// Documents directory.
    var fileURL: URL {
        Recording.recordingsDirectory.appendingPathComponent(fileName)
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Directory where recordings are stored: <Documents>/Recordings.
    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
