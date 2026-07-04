import SwiftUI
import Inject

// MARK: - Account security card (§18.2)

/// Privacy & Security card grouping the account-recovery rows: Change Password and a
/// Recovery email row (with a gentle prompt for username-only accounts to add one).
struct AccountSecurityCard: View {
    @EnvironmentObject var session: AppSession

    private var email: String? { session.currentUser?.email }
    private var emailVerified: Bool { session.currentUser?.emailVerified ?? false }

    private var recoveryValue: String {
        guard let email, !email.isEmpty else { return String(localized: "Add") }
        return emailVerified ? email : String(localized: "Unverified")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account security")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 4)

            // Gentle prompt: username-only accounts can't recover a lost password.
            if email == nil || email?.isEmpty == true {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KlicColor.primary)
                    Text("Add a recovery email so you can reset your password if you ever lose it.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            NavigationLink { ChangePasswordView() } label: {
                PrivacyRow(icon: "lock.rotation", title: String(localized: "Change Password"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink { RecoveryEmailView() } label: {
                PrivacyRow(
                    icon: "envelope.badge.shield.half.filled",
                    title: String(localized: "Recovery email"),
                    value: recoveryValue
                )
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Change password (§18.2)

struct ChangePasswordView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var errorText: String?
    @State private var done = false

    private var canSave: Bool {
        !current.isEmpty && newPassword.count >= 8 && newPassword == confirm && !saving
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    KlicTextField(placeholder: String(localized: "Current password"), text: $current, isSecure: true)
                        .textContentType(.password)
                    KlicTextField(placeholder: String(localized: "New password"), text: $newPassword, isSecure: true)
                        .textContentType(.newPassword)
                    KlicTextField(placeholder: String(localized: "Confirm new password"), text: $confirm, isSecure: true)
                        .textContentType(.newPassword)
                }

                if let errorText {
                    Text(errorText)
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }

                if done {
                    Text("Your password has been changed.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.primary)
                        .multilineTextAlignment(.center)
                }

                Text("Use at least 8 characters.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PillButton(title: String(localized: "Change Password"), isLoading: saving) {
                    Task { await save() }
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.6)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }

    private func save() async {
        errorText = nil
        done = false
        saving = true
        defer { saving = false }
        do {
            try await APIClient.shared.changePassword(currentPassword: current, newPassword: newPassword)
            done = true
            current = ""; newPassword = ""; confirm = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } catch let APIError.server(_, status) where status == 401 {
            errorText = String(localized: "Your current password is incorrect.")
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't change your password right now.")
        }
    }
}

// MARK: - Recovery email (§18.2)

struct RecoveryEmailView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession

    @State private var email = ""
    @State private var password = ""
    @State private var saving = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    private var currentEmail: String? { session.currentUser?.email }
    private var verified: Bool { session.currentUser?.emailVerified ?? false }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { trimmedEmail.contains("@") && password.count >= 1 && !saving }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let currentEmail, !currentEmail.isEmpty {
                    statusCard(currentEmail)
                }

                // Add / change form.
                VStack(alignment: .leading, spacing: 12) {
                    Text(currentEmail == nil ? String(localized: "Add a recovery email") : String(localized: "Change recovery email"))
                        .font(KlicFont.headline(15))
                        .foregroundStyle(KlicColor.textPrimary)

                    KlicTextField(placeholder: String(localized: "Email"), text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)

                    KlicTextField(placeholder: String(localized: "Current password"), text: $password, isSecure: true)
                        .textContentType(.password)

                    Text("We use your password to secure recovery. You'll get an email to verify this address.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)

                    if let errorText {
                        Text(errorText)
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.danger)
                    }

                    PillButton(title: String(localized: "Send verification"), isLoading: saving) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.6)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Recovery email")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // If an unverified email is already pending, resume polling on open.
            if let currentEmail, !currentEmail.isEmpty, !verified { startPolling() }
        }
        .onDisappear { pollTask?.cancel() }
        .enableInjection()
    }

    private func statusCard(_ address: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: verified ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(verified ? KlicColor.primary : KlicColor.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(address)
                    .font(KlicFont.medium(15))
                    .foregroundStyle(KlicColor.textPrimary)
                    .lineLimit(1)
                Text(verified ? String(localized: "Verified") : String(localized: "Awaiting verification — check your inbox"))
                    .font(KlicFont.caption(12))
                    .foregroundStyle(verified ? KlicColor.primary : KlicColor.textMuted)
            }
            Spacer(minLength: 0)
            if !verified {
                Button {
                    Task { await refreshStatus() }
                } label: {
                    Text("Refresh")
                        .font(KlicFont.medium(13))
                        .foregroundStyle(KlicColor.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(KlicColor.primary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func submit() async {
        errorText = nil
        saving = true
        defer { saving = false }
        do {
            let user = try await APIClient.shared.setRecoveryEmail(trimmedEmail, password: password)
            session.updateCurrentUser(user)
            password = ""
            email = ""
            startPolling()
        } catch let APIError.server(_, status) where status == 409 {
            errorText = String(localized: "That email is already used by another account.")
        } catch let APIError.server(_, status) where status == 401 {
            errorText = String(localized: "Your password is incorrect.")
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't add that email right now.")
        }
    }

    /// Poll GET /me/email/status until the user verifies via Firebase's hosted email.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            for _ in 0..<40 {   // ~40 × 5s ≈ 3.3 min
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                if await refreshStatus() { return }
            }
        }
    }

    /// Fetch status; mirror a verified flip into the session. Returns true once verified.
    @discardableResult
    private func refreshStatus() async -> Bool {
        guard let status = try? await APIClient.shared.emailStatus() else { return false }
        if var user = session.currentUser {
            user.email = status.email ?? user.email
            user.emailVerified = status.emailVerified
            session.updateCurrentUser(user)
        }
        return status.emailVerified
    }
}
