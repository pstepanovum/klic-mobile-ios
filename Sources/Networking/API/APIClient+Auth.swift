import Foundation

extension APIClient {
    func register(username: String, password: String, displayName: String) async throws -> AuthResponse {
        try await post("/auth/register", body: [
            "username": username, "password": password, "displayName": displayName,
        ], authed: false)
    }

    func login(username: String, password: String) async throws -> AuthResponse {
        try await post("/auth/login", body: ["username": username, "password": password], authed: false)
    }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        try await post("/auth/refresh", body: ["refreshToken": refreshToken], authed: false)
    }

    /// Revokes this login's refresh tokens server-side and, with `installId`, drops the
    /// install's push device rows so a signed-out phone stops getting pushes. Unauthed
    /// (the refresh token is the credential), so it never enters the 401-refresh path.
    func logout(refreshToken: String, installId: String?) async throws {
        var body: [String: Any] = ["refreshToken": refreshToken]
        if let installId { body["installId"] = installId }
        let _: EmptyResponse = try await post("/auth/logout", body: body, authed: false)
    }

    // MARK: Email linking (§12.2)

    /// Link + verify an email via a Google ID token; returns the updated selfUser.
    func linkGoogleEmail(idToken: String) async throws -> User {
        try await post("/me/email/google", body: ["idToken": idToken])
    }

    /// Remove the linked email. Body-less DELETE — no Content-Type header.
    func removeEmail() async throws {
        let _: EmptyResponse = try await delete("/me/email")
    }

    // MARK: Account recovery (§18.2)

    /// Change the account password (204 on success, 401 on wrong current). Also updates the
    /// Firebase Auth shadow password server-side when a shadow exists.
    func changePassword(currentPassword: String, newPassword: String) async throws {
        let _: EmptyResponse = try await post(
            "/auth/change-password",
            body: ["currentPassword": currentPassword, "newPassword": newPassword]
        )
    }

    /// Set an UNVERIFIED recovery email and trigger Firebase's verification email; returns the
    /// updated selfUser. `password` is the user's current plaintext — passing it lets the server
    /// create the Firebase shadow with a MATCHING password so a Firebase-side reset syncs back to
    /// login. 409 if the email is already verified on another account.
    func setRecoveryEmail(_ email: String, password: String) async throws -> User {
        try await post("/me/email", body: ["email": email, "password": password])
    }

    /// Poll the verification state of the pending recovery email (read from Firebase Admin).
    func emailStatus() async throws -> EmailStatus {
        try await get("/me/email/status")
    }

    // MARK: Passkeys (§10.4)

    /// Registration options for adding a passkey (auth'd). Raw JSON — the WebAuthn
    /// options dictionary is handed to AuthenticationServices almost verbatim.
    func passkeyRegisterOptions() async throws -> Data {
        try await rawRequest("/auth/passkeys/register/options", method: "POST", body: Data("{}".utf8), authed: true)
    }

    func passkeyRegisterVerify(_ payload: [String: Any]) async throws -> PasskeyCredentialInfo {
        try await post("/auth/passkeys/register/verify", body: payload)
    }

    func passkeys() async throws -> [PasskeyCredentialInfo] { try await get("/me/passkeys") }

    func deletePasskey(id: String) async throws {
        let _: EmptyResponse = try await delete("/me/passkeys/\(id)")
    }

    /// Login options (unauth'd) — returns the WebAuthn request JSON.
    func passkeyLoginOptions() async throws -> Data {
        try await rawRequest("/auth/passkeys/login/options", method: "POST", body: Data("{}".utf8), authed: false)
    }

    func passkeyLoginVerify(_ payload: [String: Any]) async throws -> AuthResponse {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await request("/auth/passkeys/login/verify", method: "POST", body: data, authed: false)
    }
}
