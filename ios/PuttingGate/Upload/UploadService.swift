import Foundation
import SwiftData

/// Uploads recorded videos to the backend using a background URLSession so
/// transfers continue if the app is suspended. Upload state is persisted
/// in SwiftData and updated as tasks complete.
@MainActor
final class UploadService: NSObject, ObservableObject {

    private let settings: AppSettings
    private let modelContainer: ModelContainer

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.puttinggate.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Maps a running URLSessionTask's identifier to the recording it is
    /// uploading, plus the temporary multipart body file to clean up on completion.
    private var inFlight: [Int: (recordingID: UUID, bodyFile: URL)] = [:]

    /// Completion handler delivered by the app delegate when the system
    /// relaunches us to finish background events.
    var backgroundCompletionHandler: (() -> Void)?

    init(settings: AppSettings, modelContainer: ModelContainer) {
        self.settings = settings
        self.modelContainer = modelContainer
        super.init()
        // Touch the lazy session so background events are delivered to us.
        _ = session
    }

    // MARK: Public API

    /// Queue every recording that still needs uploading (pending or failed).
    func uploadPending() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Recording>()
        guard let recordings = try? context.fetch(descriptor) else { return }
        for recording in recordings where recording.uploadState == .pending || recording.uploadState == .failed {
            upload(recording)
        }
    }

    /// Begin (or retry) uploading a single recording.
    func upload(_ recording: Recording) {
        guard let endpoint = settings.uploadURL else {
            mark(recordingID: recording.id, state: .failed, error: "No backend URL configured")
            return
        }
        guard recording.fileExists else {
            mark(recordingID: recording.id, state: .failed, error: "Recording file missing on disk")
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile: URL
        do {
            bodyFile = try makeMultipartBody(for: recording, boundary: boundary)
        } catch {
            mark(recordingID: recording.id, state: .failed, error: "Failed to build request: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = recording.id.uuidString
        inFlight[task.taskIdentifier] = (recording.id, bodyFile)

        recording.uploadState = .uploading
        recording.uploadAttempts += 1
        recording.lastUploadError = nil
        try? modelContainer.mainContext.save()

        task.resume()
    }

    // MARK: Multipart encoding

    /// Writes a multipart/form-data body (video + metadata) to a temp file.
    /// Background upload tasks require a file source rather than in-memory data.
    private func makeMultipartBody(for recording: Recording, boundary: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(recording.id.uuidString).multipart")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        func writeField(_ name: String, _ value: String) {
            var s = "--\(boundary)\r\n"
            s += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            s += "\(value)\r\n"
            handle.write(Data(s.utf8))
        }

        writeField("recording_id", recording.id.uuidString)
        writeField("captured_at", ISO8601DateFormatter().string(from: recording.capturedAt))
        writeField("duration", String(recording.duration))

        // File part.
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"video\"; filename=\"\(recording.fileName)\"\r\n"
        header += "Content-Type: video/quicktime\r\n\r\n"
        handle.write(Data(header.utf8))

        let fileHandle = try FileHandle(forReadingFrom: recording.fileURL)
        defer { try? fileHandle.close() }
        while case let chunk = fileHandle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            handle.write(chunk)
        }

        handle.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return tmp
    }

    // MARK: State updates

    private func mark(recordingID: UUID, state: UploadState, error: String?) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })
        guard let recording = try? context.fetch(descriptor).first else { return }
        recording.uploadState = state
        recording.lastUploadError = error
        try? context.save()
    }
}

extension UploadService: URLSessionDataDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let errorText = error?.localizedDescription

        Task { @MainActor in
            guard let entry = self.inFlight.removeValue(forKey: taskID) else { return }
            try? FileManager.default.removeItem(at: entry.bodyFile)

            if let errorText {
                self.mark(recordingID: entry.recordingID, state: .failed, error: errorText)
            } else if let code = statusCode, !(200..<300).contains(code) {
                self.mark(recordingID: entry.recordingID, state: .failed, error: "Server returned HTTP \(code)")
            } else {
                self.mark(recordingID: entry.recordingID, state: .uploaded, error: nil)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
