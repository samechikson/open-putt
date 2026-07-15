import Foundation
import SwiftData
import Combine

/// Ties the recorder to persistence and uploads: persists each finished
/// recording and enqueues its upload to the backend.
@MainActor
final class RecordingCoordinator: ObservableObject {

    let recorder: CameraRecorder
    let uploads: UploadService
    private let modelContainer: ModelContainer

    init(recorder: CameraRecorder, uploads: UploadService, modelContainer: ModelContainer) {
        self.recorder = recorder
        self.uploads = uploads
        self.modelContainer = modelContainer

        recorder.onRecordingFinished = { [weak self] url, capturedAt, duration, lengthFeet, breakType, putterID in
            self?.saveRecording(
                fileName: url.lastPathComponent, capturedAt: capturedAt,
                duration: duration, lengthFeet: lengthFeet, breakType: breakType,
                putterID: putterID
            )
        }
    }

    private func saveRecording(
        fileName: String, capturedAt: Date, duration: Double,
        lengthFeet: Int, breakType: PuttBreak, putterID: String?
    ) {
        let context = modelContainer.mainContext
        let recording = Recording(
            fileName: fileName, capturedAt: capturedAt, duration: duration,
            lengthFeet: lengthFeet, breakType: breakType, putterID: putterID
        )
        context.insert(recording)
        try? context.save()
        uploads.upload(recording)
    }
}
