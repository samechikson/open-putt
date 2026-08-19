import SwiftUI
import UIKit
import FirebaseCore

@main
struct PuttingGateApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var auth: AuthManager
    @StateObject private var config: SessionConfigStore
    @StateObject private var history: SessionHistoryStore
    @StateObject private var calibration: CalibrationStore
    @StateObject private var gate: GateConnection

    init() {
        // Must run before any Firebase API (AuthManager below). Reads
        // GoogleService-Info.plist bundled in the app target.
        FirebaseApp.configure()

        // Register the bundled Caprasimo + Figtree fonts and paint the system
        // chrome (tab/nav bars) in the warm "Organic" palette.
        PGFonts.register()
        PGAppearance.apply()

        let settings = AppSettings()
        let auth = AuthManager()
        let service = SessionMetadataService(settings: settings, auth: auth)
        let config = SessionConfigStore(service: service, auth: auth)
        let history = SessionHistoryStore(service: service)
        let calibration = CalibrationStore()
        let gate = GateConnection(
            settings: settings, auth: auth, config: config, calibration: calibration
        )

        _settings = StateObject(wrappedValue: settings)
        _auth = StateObject(wrappedValue: auth)
        _config = StateObject(wrappedValue: config)
        _history = StateObject(wrappedValue: history)
        _calibration = StateObject(wrappedValue: calibration)
        _gate = StateObject(wrappedValue: gate)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(auth)
                .environmentObject(config)
                .environmentObject(history)
                .environmentObject(calibration)
                .environmentObject(gate)
                .tint(.pgAccent)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pgScreenBackground()
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
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Paints UIKit-backed system chrome (tab bar) to match the design: a warm,
/// translucent cream bar with an accent-colored selected item. SwiftUI surfaces
/// are colored directly in each view.
enum PGAppearance {
    static func apply() {
        let bg = UIColor(Color.pgBg)
        let accent = UIColor(Color.pgAccent700)
        let inactive = UIColor(Color.pgNeutral500)

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = bg.withAlphaComponent(0.85)

        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = accent
            item.selected.titleTextAttributes = [.foregroundColor: accent]
            item.normal.iconColor = inactive
            item.normal.titleTextAttributes = [.foregroundColor: inactive]
        }

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
