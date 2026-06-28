import SwiftUI
import SwiftData

@main
struct PuttingGateApp: App {

    private let modelContainer: ModelContainer
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: SessionCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Session.self, Clip.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        let settings = AppSettings()
        let uploads = UploadService(settings: settings, modelContainer: container)
        let capture = CaptureService(settings: settings)
        let coordinator = SessionCoordinator(
            capture: capture, uploads: uploads, modelContainer: container
        )

        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(coordinator)
                .modelContainer(modelContainer)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Record", systemImage: "video.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear {
            coordinator.capture.start()
            // Resume any uploads left pending from a previous launch.
            coordinator.uploads.uploadPending()
        }
    }
}
