import Foundation
import SwiftData

/// Uploads recorded videos to the backend using a background URLSession so
/// transfers continue if the app is suspended. Upload state is persisted
/// in SwiftData and updated as tasks complete.
@MainActor
final class UploadService: NSObject, ObservableObject {

    private let settings: AppSettings
    private let modelContainer: ModelContainer
    private let auth: AuthManager

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

    /// Response bodies accumulated per task, so a failed upload can surface the
    /// server's error message (e.g. "Auto-calibration failed") instead of a bare
    /// status code. A background session delivers the body incrementally.
    private var responseBodies: [Int: Data] = [:]

    /// Completion handler delivered by the app delegate when the system
    /// relaunches us to finish background events.
    var backgroundCompletionHandler: (() -> Void)?

    init(settings: AppSettings, modelContainer: ModelContainer, auth: AuthManager) {
        self.settings = settings
        self.modelContainer = modelContainer
        self.auth = auth
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

    /// Begin (or retry) uploading a single recording. Fetching a valid auth
    /// token is async, so the work runs in a Task.
    func upload(_ recording: Recording) {
        Task { await performUpload(recording) }
    }

    private func performUpload(_ recording: Recording) async {
        guard let endpoint = settings.uploadURL else {
            mark(recordingID: recording.id, state: .failed, error: "No backend URL configured")
            return
        }
        guard recording.fileExists else {
            mark(recordingID: recording.id, state: .failed, error: "Recording file missing on disk")
            return
        }

        // Attach the signed-in user so the backend can tie the session to them.
        let accessToken = await auth.validAccessToken()
        let userID = auth.userID

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile: URL
        do {
            bodyFile = try makeMultipartBody(for: recording, boundary: boundary, userID: userID)
        } catch {
            mark(recordingID: recording.id, state: .failed, error: "Failed to build request: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

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
    private func makeMultipartBody(for recording: Recording, boundary: String, userID: String?) throws -> URL {
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
        if let userID { writeField("user_id", userID) }
        writeField("captured_at", ISO8601DateFormatter().string(from: recording.capturedAt))
        writeField("duration", String(recording.duration))
        writeField("length_feet", String(recording.lengthFeet))
        writeField("break_type", recording.breakTypeRaw)

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

    /// Accumulate the response body so a failed upload can show the server's
    /// message. Delivered before didCompleteWithError; hop to the main actor to
    /// mutate responseBodies in order with completion.
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let taskID = dataTask.taskIdentifier
        Task { @MainActor in
            self.responseBodies[taskID, default: Data()].append(data)
        }
    }

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
            let body = self.responseBodies.removeValue(forKey: taskID)
            try? FileManager.default.removeItem(at: entry.bodyFile)

            if let errorText {
                self.mark(recordingID: entry.recordingID, state: .failed, error: errorText)
            } else if let code = statusCode, !(200..<300).contains(code) {
                let message = Self.serverMessage(from: body)
                    ?? "Server returned HTTP \(code)"
                self.mark(recordingID: entry.recordingID, state: .failed, error: message)
            } else {
                self.mark(recordingID: entry.recordingID, state: .uploaded, error: nil)
            }
        }
    }

    /// Extract a human-readable message from a FastAPI error body. `detail` is a
    /// string for HTTPExceptions and an array of `{msg}` objects for request
    /// validation errors; handle both, else nil.
    private static func serverMessage(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }

        if let detail = json["detail"] as? String {
            return detail
        }
        if let items = json["detail"] as? [[String: Any]] {
            let msgs = items.compactMap { $0["msg"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "; ") }
        }
        return nil
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
