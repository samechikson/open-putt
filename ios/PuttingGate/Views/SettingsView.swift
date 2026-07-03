import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if case let .signedIn(user) = auth.state {
                        LabeledContent("Signed in as", value: user.email ?? "—")
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }

                Section("Backend") {
                    if let url = settings.uploadURL {
                        Text("Uploads to: \(url.absoluteString)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Retry pending uploads") {
                        coordinator.uploads.uploadPending()
                    }
                }

                Section("Capture") {
                    Picker("Resolution", selection: $settings.capturePresetRaw) {
                        ForEach(CapturePreset.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
