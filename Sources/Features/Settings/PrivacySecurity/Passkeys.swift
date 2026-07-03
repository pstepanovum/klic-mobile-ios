import SwiftUI
import AuthenticationServices

/// WebAuthn passkeys (§10.4): registration + assertion via
/// ASAuthorizationPlatformPublicKeyCredentialProvider against the Klic server's
/// @simplewebauthn endpoints. Degrades gracefully — AltStore re-signing can strip the
/// associated-domains entitlement, in which case the platform refuses with an error
/// we surface as a readable message (never a crash).
final class PasskeyService: NSObject {
    static let shared = PasskeyService()

    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    enum PasskeyError: LocalizedError {
        case malformedOptions
        case unsupportedCredential
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .malformedOptions:
                return String(localized: "The server sent passkey options this app couldn't read.")
            case .unsupportedCredential:
                return String(localized: "This device returned an unsupported credential type.")
            case .unavailable(let detail):
                return detail
            }
        }
    }

    // MARK: Add a passkey (auth'd)

    @MainActor
    func registerPasskey() async throws {
        let optionsData = try await APIClient.shared.passkeyRegisterOptions()
        guard let options = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
              let challengeB64 = options["challenge"] as? String,
              let challenge = Self.base64urlDecode(challengeB64),
              let rp = options["rp"] as? [String: Any],
              let rpId = rp["id"] as? String,
              let user = options["user"] as? [String: Any],
              let userName = user["name"] as? String,
              let userIdB64 = user["id"] as? String,
              let userId = Self.base64urlDecode(userIdB64) else {
            throw PasskeyError.malformedOptions
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: userName, userID: userId
        )

        let authorization = try await perform([request])
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else {
            throw PasskeyError.unsupportedCredential
        }

        let payload: [String: Any] = [
            "id": Self.base64urlEncode(credential.credentialID),
            "rawId": Self.base64urlEncode(credential.credentialID),
            "type": "public-key",
            "response": [
                "clientDataJSON": Self.base64urlEncode(credential.rawClientDataJSON),
                "attestationObject": Self.base64urlEncode(attestation),
            ],
            "clientExtensionResults": [:],
            "label": UIDevice.current.name,
        ]
        _ = try await APIClient.shared.passkeyRegisterVerify(payload)
    }

    // MARK: Sign in with a passkey (unauth'd)

    @MainActor
    func signInWithPasskey() async throws -> AuthResponse {
        let optionsData = try await APIClient.shared.passkeyLoginOptions()
        guard let options = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
              let challengeB64 = options["challenge"] as? String,
              let challenge = Self.base64urlDecode(challengeB64),
              let rpId = options["rpId"] as? String else {
            throw PasskeyError.malformedOptions
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let authorization = try await perform([request])
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.unsupportedCredential
        }

        var response: [String: Any] = [
            "clientDataJSON": Self.base64urlEncode(credential.rawClientDataJSON),
            "authenticatorData": Self.base64urlEncode(credential.rawAuthenticatorData),
            "signature": Self.base64urlEncode(credential.signature),
        ]
        if !credential.userID.isEmpty {
            response["userHandle"] = Self.base64urlEncode(credential.userID)
        }
        let payload: [String: Any] = [
            "id": Self.base64urlEncode(credential.credentialID),
            "rawId": Self.base64urlEncode(credential.credentialID),
            "type": "public-key",
            "response": response,
            "clientExtensionResults": [:],
        ]
        return try await APIClient.shared.passkeyLoginVerify(payload)
    }

    // MARK: ASAuthorizationController plumbing

    @MainActor
    private func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

extension PasskeyService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // Associated-domain failures (stripped entitlement on AltStore builds) land
        // here — hand back a readable message instead of crashing.
        let readable: Error
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            readable = CancellationError()
        } else {
            readable = PasskeyError.unavailable(
                String(localized: "Passkeys aren't available on this install. ")
                + (error as NSError).localizedDescription
            )
        }
        continuation?.resume(throwing: readable)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Passkeys settings page

struct PasskeysView: View {
    @State private var passkeys: [PasskeyCredentialInfo] = []
    @State private var loading = true
    @State private var working = false
    @State private var errorText: String?
    @State private var deleteTarget: PasskeyCredentialInfo?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView()
                            .tint(KlicColor.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if passkeys.isEmpty {
                        Text("No passkeys yet. Add one to sign in without a password.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(passkeys.enumerated()), id: \.element.id) { index, passkey in
                            passkeyRow(passkey)
                            if index < passkeys.count - 1 {
                                Divider().padding(.leading, 64).opacity(0.4)
                            }
                        }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                PillButton(title: working ? String(localized: "Adding…") : String(localized: "Add Passkey")) {
                    Task { await addPasskey() }
                }
                .disabled(working)

                if let errorText {
                    Text(errorText)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }

                Text("Passkeys use Face ID and iCloud Keychain to sign you in securely. Sideloaded builds may not support them.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Passkeys")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .klicSelectionSheet(
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            title: String(localized: "Remove this passkey?"),
            message: deleteTarget?.label,
            options: [KlicSheetOption(id: "delete", label: String(localized: "Remove Passkey"), isDestructive: true)]
        ) { _ in
            guard let target = deleteTarget else { return }
            deleteTarget = nil
            Task { await remove(target) }
        }
    }

    private func passkeyRow(_ passkey: PasskeyCredentialInfo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(passkey.label ?? String(localized: "Passkey"))
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textPrimary)
                if let created = Self.shortDate(passkey.createdAt) {
                    Text("Added \(created)")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            Spacer()
            Button { deleteTarget = passkey } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(KlicColor.danger)
                    .frame(width: 34, height: 34)
                    .background(KlicColor.danger.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = passkeys.isEmpty
        defer { loading = false }
        do {
            passkeys = try await APIClient.shared.passkeys()
            errorText = nil
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't load your passkeys.")
        }
    }

    private func addPasskey() async {
        working = true
        defer { working = false }
        errorText = nil
        do {
            try await PasskeyService.shared.registerPasskey()
            await load()
        } catch is CancellationError {
            // User dismissed the system sheet — not an error.
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = (error as NSError).localizedDescription
        }
    }

    private func remove(_ passkey: PasskeyCredentialInfo) async {
        do {
            try await APIClient.shared.deletePasskey(id: passkey.id)
            passkeys.removeAll { $0.id == passkey.id }
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't remove the passkey.")
        }
    }

    private static func shortDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        guard let date = primary.date(from: iso) ?? fallback.date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
