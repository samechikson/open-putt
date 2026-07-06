import Combine
import Foundation

/// The backend's verdict on one frame: whether the two elements calibration
/// needs — the laser gate and the resting ball — are visible.
struct CalibrationVerdict: Decodable, Equatable {
    let gateFound: Bool
    let ballFound: Bool
    let ok: Bool
    let message: String

    enum CodingKeys: String, CodingKey {
        case gateFound = "gate_found"
        case ballFound = "ball_found"
        case ok
        case message
    }
}

/// Drives the "Capture test": grabs a live frame, POSTs it to the backend
/// pre-flight endpoint, and publishes the result for the record screen.
@MainActor
final class CaptureTestModel: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case result(CalibrationVerdict)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func dismiss() { state = .idle }

    /// Run a check against `url` using an already-captured JPEG `frame`. Both are
    /// gathered by the caller (the frame from the recorder) so this stays free of
    /// capture/settings dependencies.
    func run(url: URL?, frame: Data?) {
        guard let url else {
            state = .failed("No backend URL configured.")
            return
        }
        guard let frame else {
            state = .failed("Couldn't capture a frame — give the camera a moment and try again.")
            return
        }
        state = .checking
        Task {
            do {
                state = .result(try await Self.postFrame(frame, to: url))
            } catch {
                state = .failed("Couldn't reach the analyzer. Check your connection and try again.")
            }
        }
    }

    private static func postFrame(_ jpeg: Data, to url: URL) async throws -> CalibrationVerdict {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"frame\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CalibrationVerdict.self, from: data)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
