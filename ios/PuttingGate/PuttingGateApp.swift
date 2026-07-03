import SwiftUI
import SwiftData

@main
struct PuttingGateApp: App {

    private let modelContainer: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: RecordingCoordinator
    @StateObject private var auth: AuthManager

    init() {
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

        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
        _auth = StateObject(wrappedValue: auth)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .environmentObject(coordinator.recorder)
                .environmentObject(auth)
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
