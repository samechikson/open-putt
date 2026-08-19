import Foundation
import SwiftUI

/// App-wide settings/config, shared as an ObservableObject.
final class AppSettings: ObservableObject {

    /// Base URL of the deployed backend on Cloud Run. Hardcoded so the app
    /// always talks to production; not user-configurable. The API is mounted
    /// under /api (see backend/app/main.py); iOS calls Cloud Run directly, so
    /// the prefix is part of the base URL.
    static let backendBaseURL = "https://putting-gate-backend-tksj5yumxa-uc.a.run.app/api"

    /// Endpoint that ingests one putt from the hardware gate, relayed by the app
    /// over BLE under the user's login.
    var devicePuttsURL: URL? { URL(string: Self.backendBaseURL + "/device/putts") }

    /// The signed-in user's putters, for the session-setup picker.
    var puttersURL: URL? { URL(string: Self.backendBaseURL + "/putters") }

    /// All of the signed-in user's sessions (newest first), for the History tab.
    var sessionsURL: URL? { URL(string: Self.backendBaseURL + "/sessions") }

    /// Per-putt offsets across a set of sessions, for the History bias summary.
    var puttsOffsetsURL: URL? { URL(string: Self.backendBaseURL + "/putts/offsets") }

    /// One session, used to PATCH its metadata (putter / length / break).
    func sessionURL(id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: Self.backendBaseURL + "/sessions/" + encoded)
    }

    /// One putt within a session, used to DELETE it (a mishit or false trip).
    func puttURL(sessionId: String, puttIndex: Int) -> URL? {
        guard let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: Self.backendBaseURL + "/sessions/" + encoded + "/putts/\(puttIndex)")
    }
}
