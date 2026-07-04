import SwiftUI
import UIKit
import GoogleSignIn

// MARK: - Google sign-in plumbing (§12.2)

enum GoogleEmailLinkError: LocalizedError {
    case notConfigured
    case noPresenter
    case noIdToken
    case canceled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Email linking isn't set up yet. Please try again after the next update.")
        case .noPresenter, .noIdToken:
            return String(localized: "Couldn't complete Google sign-in. Please try again.")
        case .canceled:
            return nil
        }
    }
}

/// Runs the Google sign-in flow and returns the ID token the server verifies
/// (POST /me/email/google). The iOS OAuth client id is read from Info.plist
/// (GIDClientID); while it's absent/placeholder the feature degrades gracefully.
/// §13.5: the WEB client (GIDServerClientID) is passed as serverClientID so the
/// minted ID token's audience matches the server's GOOGLE_OAUTH_CLIENT_IDS.
@MainActor
enum GoogleEmailLink {
    /// A usable client id, or nil when unset/placeholder.
    static var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !id.contains("YOUR_") else { return nil }
        return id
    }

    /// The server's WEB OAuth client — the audience the ID token is minted for (§13.5).
    static var serverClientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !id.contains("YOUR_") else { return nil }
        return id
    }

    static var isConfigured: Bool { clientID != nil }

    static func acquireIdToken() async throws -> String {
        guard let clientID else { throw GoogleEmailLinkError.notConfigured }
        guard let presenter = topViewController() else { throw GoogleEmailLinkError.noPresenter }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else {
                throw GoogleEmailLinkError.noIdToken
            }
            return token
        } catch let error as GIDSignInError where error.code == .canceled {
            throw GoogleEmailLinkError.canceled
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Email row (Settings account area, §12.2)

/// "Email" card: none → "Add email" via Google sign-in; linked → the address with a
/// "Verified" badge and a confirmed remove (DELETE /me/email).
struct AccountEmailCard: View {
    @EnvironmentObject var session: AppSession

    @State private var linking = false
    @State private var removing = false
    @State private var showRemoveConfirm = false
    @State private var error: String?

    private var email: String? {
        let value = session.currentUser?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var verified: Bool { session.currentUser?.emailVerified == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email")
                .font(KlicFont.caption())
                .foregroundStyle(KlicColor.textMuted)

            if let email {
                linkedRow(email)
            } else {
                addRow
            }

            if let error {
                Text(error)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.danger)
                    .padding(.horizontal, 4)
            }
        }
        .klicSelectionSheet(
            isPresented: $showRemoveConfirm,
            title: String(localized: "Remove email?"),
            message: String(localized: "Your email will no longer be linked to this account."),
            options: [KlicSheetOption(id: "remove", label: String(localized: "Remove email"), isDestructive: true)]
        ) { _ in
            Task { await removeEmail() }
        }
    }

    private func linkedRow(_ email: String) -> some View {
        Button { showRemoveConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KlicColor.primary)
                Text(email)
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if verified {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Verified")
                            .font(KlicFont.caption(11))
                    }
                    .foregroundStyle(KlicColor.read)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(KlicColor.read.opacity(0.12), in: Capsule())
                }
                Spacer()
                if removing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(KlicColor.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(removing)
    }

    private var addRow: some View {
        Button { Task { await addEmail() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KlicColor.primary)
                Text("Add email")
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textPrimary)
                Spacer()
                if linking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(KlicColor.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(linking)
    }

    private func addEmail() async {
        error = nil
        guard GoogleEmailLink.isConfigured else {
            error = String(localized: "Email linking isn't set up yet. Please try again after the next update.")
            return
        }
        linking = true
        defer { linking = false }
        do {
            let idToken = try await GoogleEmailLink.acquireIdToken()
            let user = try await APIClient.shared.linkGoogleEmail(idToken: idToken)
            session.updateCurrentUser(user)
        } catch GoogleEmailLinkError.canceled {
            // The user backed out — nothing to report.
        } catch let e as APIError {
            error = e.userMessage
        } catch let e as GoogleEmailLinkError {
            error = e.errorDescription
        } catch {
            self.error = String(localized: "Couldn't link your email. Please try again.")
        }
    }

    private func removeEmail() async {
        error = nil
        removing = true
        defer { removing = false }
        do {
            try await APIClient.shared.removeEmail()
            if var user = session.currentUser {
                user.email = nil
                user.emailVerified = false
                session.updateCurrentUser(user)
            }
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = String(localized: "Couldn't remove your email. Please try again.")
        }
    }
}
