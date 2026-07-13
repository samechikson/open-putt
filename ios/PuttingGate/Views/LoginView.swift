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
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 4) {
                Image(systemName: "target")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("Putting Gate")
                    .font(.largeTitle.bold())
                Text(mode == .signIn ? "Sign in to your account" : "Create an account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                SecureField("Password", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submit) {
                    if busy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(mode == .signIn ? "Sign in" : "Sign up")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(busy || email.isEmpty || password.isEmpty)
            }
            .padding(.horizontal)

            Button {
                mode = mode == .signIn ? .signUp : .signIn
                errorText = nil
                notice = nil
            } label: {
                Text(mode == .signIn ? "No account? Sign up" : "Have an account? Sign in")
                    .font(.footnote)
            }

            if mode == .signIn {
                Button("Forgot password?", action: resetPassword)
                    .font(.footnote)
                    .disabled(busy)
            }

            Spacer()
            Spacer()
        }
        .padding()
    }

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
