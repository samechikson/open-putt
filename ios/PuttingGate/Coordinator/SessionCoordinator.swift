import Foundation
import SwiftData
import Combine

/// Ties the capture pipeline to persistence and uploads: starts/ends sessions,
/// persists each recorded clip, and enqueues its upload.
@MainActor
final class SessionCoordinator: ObservableObject {

    let capture: CaptureService
    let uploads: UploadService
    private let modelContainer: ModelContainer

    @Published private(set) var currentSession: Session?

    init(capture: CaptureService, uploads: UploadService, modelContainer: ModelContainer) {
        self.capture = capture
        self.uploads = uploads
        self.modelContainer = modelContainer

        capture.onClipRecorded = { [weak self] url, capturedAt, duration, index in
            self?.recordClip(fileName: url.lastPathComponent, capturedAt: capturedAt,
                             duration: duration, index: index)
        }
    }

    var isSessionActive: Bool { currentSession != nil }

    func startSession() {
        let session = Session()
        let context = modelContainer.mainContext
        context.insert(session)
        try? context.save()
        currentSession = session
        capture.startSession()
    }

    func endSession() {
        capture.endSession()
        if let session = currentSession {
            session.endedAt = .now
            try? modelContainer.mainContext.save()
        }
        currentSession = nil
        // Make sure anything still pending gets pushed.
        uploads.uploadPending()
    }

    private func recordClip(fileName: String, capturedAt: Date, duration: Double, index: Int) {
        let context = modelContainer.mainContext
        let clip = Clip(fileName: fileName, capturedAt: capturedAt, duration: duration, clipIndex: index)
        clip.session = currentSession
        context.insert(clip)
        try? context.save()
        uploads.upload(clip)
    }
}
