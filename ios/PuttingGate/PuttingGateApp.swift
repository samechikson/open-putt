import SwiftUI
import FirebaseCore

@main
struct PuttingGateApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var auth: AuthManager
    @StateObject private var gate: GateConnection

    init() {
        // Must run before any Firebase API (AuthManager below). Reads
        // GoogleService-Info.plist bundled in the app target.
        FirebaseApp.configure()

        let settings = AppSettings()
        let auth = AuthManager()
        let gate = GateConnection(settings: settings, auth: auth)

        _settings = StateObject(wrappedValue: settings)
        _auth = StateObject(wrappedValue: auth)
        _gate = StateObject(wrappedValue: gate)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(auth)
                .environmentObject(gate)
        }
    }
}

/// Gates the app behind auth: shows the login screen until there's a session,
/// and the tab UI once signed in.
struct RootView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            LoginView()
        case .signedIn:
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            GateView()
                .tabItem { Label("Gate", systemImage: "sensor.tag.radiowaves.forward.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
