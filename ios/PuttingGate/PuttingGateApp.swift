import SwiftUI
import SwiftData

@main
struct PuttingGateApp: App {

    private let modelContainer: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Recording.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        let settings = AppSettings()
        let uploads = UploadService(settings: settings, modelContainer: container)
        let recorder = CameraRecorder(settings: settings)
        let coordinator = RecordingCoordinator(
            recorder: recorder, uploads: uploads, modelContainer: container
        )

        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .environmentObject(coordinator.recorder)
                .modelContainer(modelContainer)
        }
    }
}

struct RootView: View {
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
