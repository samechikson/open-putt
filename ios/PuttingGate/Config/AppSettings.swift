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
}
