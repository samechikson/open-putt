import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    private enum Mode { case signIn, signUp }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 36) {
            Spacer()

            VStack(spacing: 10) {
                PGLogo(size: 52)
                Text("Putting Gate")
                    .font(.pgHeading(26, relativeTo: .largeTitle))
                    .foregroundStyle(Color.pgText)
                Text(mode == .signIn ? "Sign in to your account" : "Create an account")
                    .font(.pgBody(14))
                    .foregroundStyle(Color.pgNeutral700)
            }

            VStack(spacing: 16) {
                field(label: "Email") {
                    TextField("you@email.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field(label: "Password") {
                    SecureField("••••••••", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                }

                if let errorText {
                    message(errorText, color: .pgAccent700)
                }
                if let notice {
                    message(notice, color: .pgAccent2_700)
                }

                Button(action: submit) {
                    if busy {
                        ProgressView().tint(.pgBg).frame(maxWidth: .infinity)
                    } else {
                        Text(mode == .signIn ? "Sign in" : "Sign up")
                    }
                }
                .buttonStyle(PGPrimaryButtonStyle())
                .disabled(busy || email.isEmpty || password.isEmpty)
                .opacity(busy || email.isEmpty || password.isEmpty ? 0.55 : 1)
                .padding(.top, 6)

                Button {
                    mode = mode == .signIn ? .signUp : .signIn
                    errorText = nil
                    notice = nil
                } label: {
                    Text(mode == .signIn ? "No account? Sign up" : "Have an account? Sign in")
                }
                .buttonStyle(PGGhostButtonStyle())
                .frame(maxWidth: .infinity)

                if mode == .signIn {
                    Button("Forgot password?", action: resetPassword)
                        .buttonStyle(PGGhostButtonStyle(color: .pgNeutral700, size: 13))
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                }
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
    }

    // MARK: Pieces

    private func field<Content: View>(label: String, @ViewBuilder _ input: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.pgBody(12))
                .foregroundStyle(Color.pgText.opacity(0.7))
            input()
                .font(.pgBody(15))
                .foregroundStyle(Color.pgText)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.pgSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.pgDivider, lineWidth: 1))
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.pgBody(13))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func resetPassword() {
        guard !email.isEmpty else {
            errorText = "Enter your email above first, then tap Forgot password."
            return
        }
        busy = true
        errorText = nil
        notice = nil
        Task {
            do {
                try await auth.resetPassword(email: email)
                notice = "Password reset email sent. Check your inbox."
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func submit() {
        busy = true
        errorText = nil
        notice = nil
        Task {
            do {
                if mode == .signUp {
                    let signedIn = try await auth.signUp(email: email, password: password)
                    if !signedIn {
                        notice = "Check your email to confirm your account, then sign in."
                        mode = .signIn
                    }
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
