import Foundation

enum FirebaseRecoveryError: LocalizedError {
    case notConfigured
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Password recovery isn't set up yet. Please try again after the next update.")
        case .requestFailed:
            return String(localized: "Couldn't send the reset email. Please try again.")
        }
    }
}

/// Client half of the §18.2 account-recovery flow: Firebase Auth's hosted password-reset email.
///
/// Implemented against the Firebase Identity Toolkit REST endpoint (`accounts:sendOobCode`) using
/// the Firebase Web API key, rather than linking the full Firebase iOS SDK — no iOS app is
/// registered in the Firebase project yet (no GoogleService-Info.plist), so the SDK couldn't
/// initialize at runtime regardless, and the REST call produces the identical hosted email. Swap
/// to `Auth.auth().sendPasswordResetEmail` once an iOS Firebase app is provisioned. The key is
/// read from config (`AppConfig.firebaseWebAPIKey`) and the feature degrades gracefully when unset.
enum FirebaseRecovery {
    static var isConfigured: Bool { AppConfig.firebaseWebAPIKey != nil }

    /// Send Firebase's hosted password-reset email for `email`. Callers surface a uniform
    /// "check your email" message regardless of whether the address exists (enumeration).
    static func sendPasswordReset(email: String) async throws {
        guard let key = AppConfig.firebaseWebAPIKey else { throw FirebaseRecoveryError.notConfigured }
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=\(key)") else {
            throw FirebaseRecoveryError.requestFailed
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "requestType": "PASSWORD_RESET",
            "email": email,
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Firebase returns 400 EMAIL_NOT_FOUND for unknown addresses — the caller treats this
            // the same as success so the UI never reveals whether the email is registered.
            throw FirebaseRecoveryError.requestFailed
        }
    }
}
