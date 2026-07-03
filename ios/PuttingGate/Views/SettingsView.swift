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
                    TextField("Base URL (e.g. http://192.168.1.20:8000)", text: $settings.backendBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Upload path", text: $settings.uploadPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = settings.uploadURL {
                        Text("Uploads to: \(url.absoluteString)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Enter a valid base URL to enable uploads.")
                            .font(.caption).foregroundStyle(.orange)
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
