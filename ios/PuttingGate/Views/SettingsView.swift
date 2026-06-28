import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Motion detection") {
                    sliderRow("Sensitivity", value: $settings.motionThreshold,
                              range: 0.01...0.2, format: "%.3f",
                              hint: "Lower triggers more easily")
                    sliderRow("Cooldown (s)", value: $settings.cooldownSeconds,
                              range: 0.5...5, format: "%.1f",
                              hint: "Gap enforced between clips")
                }

                Section("Clip timing") {
                    sliderRow("Pre-roll (s)", value: $settings.preRollSeconds,
                              range: 0...3, format: "%.1f",
                              hint: "Footage kept before motion")
                    sliderRow("Post-roll (s)", value: $settings.postRollSeconds,
                              range: 0...3, format: "%.1f",
                              hint: "Footage kept after motion stops")
                    sliderRow("Max clip (s)", value: $settings.maxClipSeconds,
                              range: 2...20, format: "%.0f",
                              hint: "Safety cap on clip length")
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

    private func sliderRow(
        _ title: String, value: Binding<Double>,
        range: ClosedRange<Double>, format: String, hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
