import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        VStack(spacing: 0) {
            PGHeader("Settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        PGSectionHeader("Account")
                        VStack(spacing: 0) {
                            if case let .signedIn(user) = auth.state {
                                row {
                                    Text("Signed in as")
                                        .font(.pgBody(15))
                                        .foregroundStyle(Color.pgNeutral700)
                                    Spacer()
                                    Text(user.email ?? "—")
                                        .font(.pgBody(15, weight: .semibold))
                                        .foregroundStyle(Color.pgText)
                                }
                                PGDivider()
                            }
                            Button {
                                Task { await auth.signOut() }
                            } label: {
                                row {
                                    Text("Sign out")
                                        .font(.pgBody(15, weight: .semibold))
                                        .foregroundStyle(Color.pgAccent700)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .pgCard()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        PGSectionHeader("Backend")
                        row {
                            Text(AppSettings.backendBaseURL)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.pgNeutral700)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .pgCard()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
    }
}
