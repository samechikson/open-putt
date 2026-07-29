import SwiftUI
import SwiftData
import FirebaseCore

@main
struct PuttingGateApp: App {

    private let modelContainer: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: RecordingCoordinator
    @StateObject private var auth: AuthManager
    @StateObject private var gate: GateConnection

    init() {
        // Must run before any Firebase API (AuthManager below). Reads
        // GoogleService-Info.plist bundled in the app target.
        FirebaseApp.configure()

        let container: ModelContainer
        do {
            container = try ModelContainer(for: Recording.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        let settings = AppSettings()
        let auth = AuthManager()
        let uploads = UploadService(settings: settings, modelContainer: container, auth: auth)
        let recorder = CameraRecorder(settings: settings)
        let coordinator = RecordingCoordinator(
            recorder: recorder, uploads: uploads, modelContainer: container
        )

        let gate = GateConnection(settings: settings, auth: auth)

        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
        _auth = StateObject(wrappedValue: auth)
        _gate = StateObject(wrappedValue: gate)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .environmentObject(coordinator.recorder)
                .environmentObject(auth)
                .environmentObject(gate)
                .modelContainer(modelContainer)
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
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "video.fill") }
            GateView()
                .tabItem { Label("Gate", systemImage: "sensor.tag.radiowaves.forward.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear {
            coordinator.recorder.start()
            // Resume any uploads left pending from a previous launch.
            coordinator.uploads.uploadPending()
        }
    }
}
