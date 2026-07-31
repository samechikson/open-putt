import SwiftUI

struct SettingsView: View {
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
                    Text(AppSettings.backendBaseURL)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
