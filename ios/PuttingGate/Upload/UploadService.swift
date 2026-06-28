import Foundation
import SwiftData

/// Uploads recorded clips to the backend using a background URLSession so
/// transfers continue if the app is suspended. Clip upload state is persisted
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

    /// Maps a running URLSessionTask's identifier to the clip it is uploading,
    /// plus the temporary multipart body file to clean up on completion.
    private var inFlight: [Int: (clipID: UUID, bodyFile: URL)] = [:]

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

    /// Queue every clip that still needs uploading (pending or failed).
    func uploadPending() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Clip>()
        guard let clips = try? context.fetch(descriptor) else { return }
        for clip in clips where clip.uploadState == .pending || clip.uploadState == .failed {
            upload(clip)
        }
    }

    /// Begin (or retry) uploading a single clip.
    func upload(_ clip: Clip) {
        guard let endpoint = settings.uploadURL else {
            mark(clipID: clip.id, state: .failed, error: "No backend URL configured")
            return
        }
        guard clip.fileExists else {
            mark(clipID: clip.id, state: .failed, error: "Clip file missing on disk")
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile: URL
        do {
            bodyFile = try makeMultipartBody(for: clip, boundary: boundary)
        } catch {
            mark(clipID: clip.id, state: .failed, error: "Failed to build request: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = clip.id.uuidString
        inFlight[task.taskIdentifier] = (clip.id, bodyFile)

        clip.uploadState = .uploading
        clip.uploadAttempts += 1
        clip.lastUploadError = nil
        try? modelContainer.mainContext.save()

        task.resume()
    }

    // MARK: Multipart encoding

    /// Writes a multipart/form-data body (clip + metadata) to a temp file.
    /// Background upload tasks require a file source rather than in-memory data.
    private func makeMultipartBody(for clip: Clip, boundary: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(clip.id.uuidString).multipart")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        func writeField(_ name: String, _ value: String) {
            var s = "--\(boundary)\r\n"
            s += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            s += "\(value)\r\n"
            handle.write(Data(s.utf8))
        }

        writeField("session_id", clip.session?.id.uuidString ?? "")
        writeField("clip_id", clip.id.uuidString)
        writeField("clip_index", String(clip.clipIndex))
        writeField("captured_at", ISO8601DateFormatter().string(from: clip.capturedAt))
        writeField("duration", String(clip.duration))

        // File part.
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"video\"; filename=\"\(clip.fileName)\"\r\n"
        header += "Content-Type: video/quicktime\r\n\r\n"
        handle.write(Data(header.utf8))

        let fileHandle = try FileHandle(forReadingFrom: clip.fileURL)
        defer { try? fileHandle.close() }
        while case let chunk = fileHandle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            handle.write(chunk)
        }

        handle.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return tmp
    }

    // MARK: State updates

    private func mark(clipID: UUID, state: UploadState, error: String?) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Clip>(predicate: #Predicate { $0.id == clipID })
        guard let clip = try? context.fetch(descriptor).first else { return }
        clip.uploadState = state
        clip.lastUploadError = error
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
                self.mark(clipID: entry.clipID, state: .failed, error: errorText)
            } else if let code = statusCode, !(200..<300).contains(code) {
                self.mark(clipID: entry.clipID, state: .failed, error: "Server returned HTTP \(code)")
            } else {
                self.mark(clipID: entry.clipID, state: .uploaded, error: nil)
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
