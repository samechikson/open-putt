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

/// Drives the "Capture test" as a background auto-calibration loop: on an
/// interval it grabs a live frame, POSTs it to the backend pre-flight endpoint,
/// and publishes the result for the record screen — so the scene is dialed in
/// before recording. The loop stops once a check passes (`ok`) to avoid hammering
/// the endpoint, and is re-armed by the view on meaningful events (recording
/// finished, foregrounded, tab re-entered, or a tap to re-check).
@MainActor
final class CaptureTestModel: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case result(CalibrationVerdict)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// True while a check is in flight *and* a prior result is already showing,
    /// so the card can show a subtle spinner without blanking the last verdict.
    @Published private(set) var isRefreshing = false

    private var autoTask: Task<Void, Never>?

    /// Whether the latest verdict passed — the record screen's "ready" signal.
    var isReady: Bool {
        if case let .result(verdict) = state { return verdict.ok }
        return false
    }

    /// Start (or re-arm) the auto-check loop. Runs one check immediately, then
    /// repeats every `interval` seconds until a check passes, at which point it
    /// settles and stops polling. Calling it again cancels any running loop and
    /// starts fresh — this is also the "re-check now" entry point.
    ///
    /// `frameProvider` yields the latest camera frame as JPEG (from the
    /// recorder); `auth` supplies the Firebase ID token the backend requires.
    func startAuto(
        url: URL?,
        auth: AuthManager,
        frameProvider: @escaping () -> Data?,
        interval: TimeInterval = 10
    ) {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let outcome = await self.tick(
                    url: url, auth: auth, frameProvider: frameProvider
                )
                if outcome == .passed { break } // settle on "ready"; stop polling
                // Retry fast while the camera warms up (no frame yet); otherwise
                // wait the full interval before the next check.
                let delay = outcome == .noFrame ? 1.0 : interval
                try? await Task.sleep(for: .seconds(delay))
            }
            self.isRefreshing = false
        }
    }

    private enum TickOutcome { case passed, notReady, noFrame }

    /// Stop the loop (e.g. while recording or backgrounded). Leaves `state` as-is
    /// so the last verdict stays available; the view hides the card as needed.
    func stopAuto() {
        autoTask?.cancel()
        autoTask = nil
        isRefreshing = false
    }

    /// Run one check. Returns the outcome, which the loop uses to decide whether
    /// to settle (`.passed`), retry soon (`.noFrame`), or wait the full interval.
    private func tick(
        url: URL?,
        auth: AuthManager,
        frameProvider: @escaping () -> Data?
    ) async -> TickOutcome {
        guard let url else {
            state = .failed("No backend URL configured.")
            return .notReady
        }
        // No frame yet (camera still warming up): keep whatever we're showing and
        // try again soon rather than flashing an error.
        guard let frame = frameProvider() else { return .noFrame }

        // Refresh in place when a result is already showing; only show the full
        // "checking" state on the very first check so the card doesn't flicker.
        let hadResult: Bool
        if case .result = state {
            hadResult = true
            isRefreshing = true
        } else {
            hadResult = false
            state = .checking
        }
        defer { isRefreshing = false }

        do {
            let token = await auth.validAccessToken()
            let verdict = try await Self.postFrame(frame, to: url, token: token)
            state = .result(verdict)
            return verdict.ok ? .passed : .notReady
        } catch {
            // Ignore a transient blip when we already have a verdict on screen;
            // otherwise surface a friendly failure.
            if !hadResult {
                state = .failed(
                    "Couldn't reach the analyzer. Check your connection and try again."
                )
            }
            return .notReady
        }
    }

    private static func postFrame(
        _ jpeg: Data, to url: URL, token: String?
    ) async throws -> CalibrationVerdict {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
