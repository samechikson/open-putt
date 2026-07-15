import Foundation
import SwiftData

/// Uploads recorded videos to the backend. Because Cloud Run caps request
/// bodies, the video is PUT straight to Cloud Storage via a signed URL (on a
/// background URLSession so it survives suspension); a small JSON call then
/// queues analysis. Upload state is persisted in SwiftData.
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

    /// Context for an in-flight PUT: which recording it belongs to and the GCS
    /// object it targets. Also encoded into `taskDescription` so it survives an
    /// app relaunch, when the in-memory map is empty.
    private struct Context {
        let recordingID: UUID
        let objectName: String
    }
    private var inFlight: [Int: Context] = [:]

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

    /// Begin (or retry) uploading a single recording.
    func upload(_ recording: Recording) {
        Task { await performUpload(recording) }
    }

    private func performUpload(_ recording: Recording) async {
        // Capture value types up front: after the `await` below the recording may
        // have been deleted, and touching a deleted SwiftData model is unsafe.
        let recordingID = recording.id
        let fileURL = recording.fileURL
        let fileName = recording.fileName

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            mark(recordingID: recordingID, state: .failed, error: "Recording file missing on disk")
            return
        }
        guard let uploadsURL = settings.uploadsURL else {
            mark(recordingID: recordingID, state: .failed, error: "No backend URL configured")
            return
        }

        let accessToken = await auth.validAccessToken()

        // Step 1: ask the backend for a signed upload URL.
        let signed: (objectName: String, uploadURL: URL)
        do {
            signed = try await requestUploadURL(
                uploadsURL, recordingID: recordingID,
                fileName: fileName, accessToken: accessToken
            )
        } catch {
            mark(recordingID: recordingID, state: .failed,
                 error: "Couldn't start upload: \(error.localizedDescription)")
            return
        }

        // The recording may have been deleted while awaiting. Re-check right
        // before creating the task (no await between here and uploadTask, so the
        // file can't disappear underneath us) — uploadTask(fromFile:) raises an
        // uncatchable exception if the file is missing.
        guard fetchRecording(recordingID) != nil,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        // Step 2: PUT the video straight to Cloud Storage on the background session.
        var request = URLRequest(url: signed.uploadURL)
        request.httpMethod = "PUT"
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = "\(recordingID.uuidString)|\(signed.objectName)"
        inFlight[task.taskIdentifier] = Context(recordingID: recordingID, objectName: signed.objectName)

        if let rec = fetchRecording(recordingID) {
            rec.uploadState = .uploading
            rec.uploadAttempts += 1
            rec.lastUploadError = nil
            try? modelContainer.mainContext.save()
        }

        task.resume()
    }

    /// Best-effort delete of the backend session (putts, row, retained video) for
    /// a recording being removed locally. The recording id is the session id.
    func deleteRemoteSession(recordingID: UUID) {
        guard let url = URL(
            string: AppSettings.backendBaseURL + "/sessions/\(recordingID.uuidString)"
        ) else { return }
        Task {
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            if let token = await auth.validAccessToken() {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Cancel any in-flight upload for a recording — call before deleting it so a
    /// running task doesn't read a file that's about to be removed.
    func cancelUpload(recordingID: UUID) {
        inFlight = inFlight.filter { $0.value.recordingID != recordingID }
        let prefix = "\(recordingID.uuidString)|"
        session.getAllTasks { tasks in
            for task in tasks where (task.taskDescription ?? "").hasPrefix(prefix) {
                task.cancel()
            }
        }
    }

    // MARK: Backend calls (small JSON, foreground)

    private func requestUploadURL(
        _ url: URL, recordingID: UUID, fileName: String, accessToken: String?
    ) async throws -> (objectName: String, uploadURL: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": fileName,
            "recording_id": recordingID.uuidString,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadError(message: Self.serverMessage(from: data) ?? "Could not start upload")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objectName = json["object_name"] as? String,
              let uploadURLString = json["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLString)
        else {
            throw UploadError(message: "Unexpected response from server")
        }
        return (objectName, uploadURL)
    }

    /// Step 3: after the video is in Cloud Storage, queue analysis of it.
    private func startAnalysis(for ctx: Context) async {
        guard let recording = fetchRecording(ctx.recordingID) else { return }
        guard let url = settings.analyzeSessionURL else {
            mark(recordingID: ctx.recordingID, state: .failed, error: "No backend URL configured")
            return
        }
        let accessToken = await auth.validAccessToken()

        var body: [String: Any] = [
            "session_id": recording.id.uuidString,
            "object_name": ctx.objectName,
            "file_name": recording.fileName,
            "captured_at": ISO8601DateFormatter().string(from: recording.capturedAt),
            "duration": recording.duration,
            "length_feet": recording.lengthFeet,
            "break_type": recording.breakTypeRaw,
        ]
        if let putterID = recording.putterID { body["putter_id"] = putterID }
        if let userID = auth.userID { body["user_id"] = userID }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                mark(recordingID: ctx.recordingID, state: .uploaded, error: nil)
            } else {
                let msg = Self.serverMessage(from: data) ?? "Could not start analysis"
                mark(recordingID: ctx.recordingID, state: .failed, error: msg)
            }
        } catch {
            mark(recordingID: ctx.recordingID, state: .failed,
                 error: "Could not start analysis: \(error.localizedDescription)")
        }
    }

    // MARK: State

    private func fetchRecording(_ id: UUID) -> Recording? {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        return try? modelContainer.mainContext.fetch(descriptor).first
    }

    private func mark(recordingID: UUID, state: UploadState, error: String?) {
        guard let recording = fetchRecording(recordingID) else { return }
        recording.uploadState = state
        recording.lastUploadError = error
        try? modelContainer.mainContext.save()
    }

    /// Extract a human-readable message from a FastAPI error body (`detail` is a
    /// string for HTTPExceptions, an array of `{msg}` for validation errors).
    private static func serverMessage(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        if let detail = json["detail"] as? String { return detail }
        if let items = json["detail"] as? [[String: Any]] {
            let msgs = items.compactMap { $0["msg"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "; ") }
        }
        return nil
    }
}

private struct UploadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension UploadService: URLSessionDataDelegate {

    /// The background PUT to Cloud Storage finished. On success, kick off the
    /// analyze-session call; otherwise record the failure.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let errorText = error?.localizedDescription
        let description = task.taskDescription

        Task { @MainActor in
            // Prefer the in-memory context; fall back to the encoded description
            // when the app was relaunched to deliver this event.
            let ctx = self.inFlight.removeValue(forKey: taskID) ?? Self.context(from: description)
            guard let ctx else { return }

            if let errorText {
                self.mark(recordingID: ctx.recordingID, state: .failed, error: errorText)
            } else if let code = statusCode, !(200..<300).contains(code) {
                self.mark(recordingID: ctx.recordingID, state: .failed,
                          error: "Video upload failed (HTTP \(code))")
            } else {
                await self.startAnalysis(for: ctx)
            }
        }
    }

    private static func context(from description: String?) -> Context? {
        guard let parts = description?.split(separator: "|", maxSplits: 1),
              parts.count == 2, let id = UUID(uuidString: String(parts[0]))
        else { return nil }
        return Context(recordingID: id, objectName: String(parts[1]))
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
