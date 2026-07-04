import SwiftUI
import Inject

/// §18.2 "Forgot password?" — the user enters their recovery email and we trigger Firebase's
/// hosted password-reset email. The confirmation is uniform ("check your email") regardless of
/// whether the address is registered, so it never reveals which emails have accounts. After
/// resetting on Firebase's page they sign in with the new password; the server sync-back
/// (transparent to the client) re-hashes it into Postgres on that next login.
struct ForgotPasswordView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) private var dismiss

    var initialEmail: String = ""

    @State private var email = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { trimmed.contains("@") && !sending }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        Image(systemName: sent ? "envelope.badge.fill" : "key.horizontal.fill")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(KlicColor.primary)
                            .frame(width: 92, height: 92)
                            .background(KlicColor.primary.opacity(0.12), in: Circle())
                            .padding(.top, 8)

                        Text(sent ? String(localized: "Check your email") : String(localized: "Reset your password"))
                            .font(KlicFont.headline(22))
                            .foregroundStyle(KlicColor.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(sent
                            ? String(localized: "If an account uses this email, we've sent a link to reset your password. Follow it, then sign in with your new password.")
                            : String(localized: "Enter the email on your account and we'll send a link to reset your password."))
                            .font(KlicFont.body(15))
                            .foregroundStyle(KlicColor.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }

                    if !sent {
                        KlicTextField(placeholder: String(localized: "Email"), text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .focused($focused)

                        if let errorText {
                            Text(errorText)
                                .font(KlicFont.caption(12))
                                .foregroundStyle(KlicColor.danger)
                                .multilineTextAlignment(.center)
                        }

                        PillButton(
                            title: String(localized: "Send reset link"),
                            isLoading: sending
                        ) {
                            Task { await send() }
                        }
                        .disabled(!canSend)
                        .opacity(canSend ? 1 : 0.6)
                    } else {
                        PillButton(title: String(localized: "Done")) { dismiss() }
                    }
                }
                .padding(24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close")) { dismiss() }
                        .foregroundStyle(KlicColor.primary)
                }
            }
        }
        .onAppear {
            email = initialEmail
            focused = initialEmail.isEmpty
        }
        .enableInjection()
    }

    private func send() async {
        errorText = nil
        sending = true
        defer { sending = false }
        do {
            try await FirebaseRecovery.sendPasswordReset(email: trimmed)
        } catch FirebaseRecoveryError.notConfigured {
            errorText = FirebaseRecoveryError.notConfigured.errorDescription
            return
        } catch {
            // Any other failure (incl. Firebase's EMAIL_NOT_FOUND) still shows the uniform
            // confirmation so we never disclose whether the address is registered.
        }
        withAnimation { sent = true }
    }
}
