import Foundation

enum AppConfig {
    private static let productionAPIOrigin = "https://api.89.34.230.2.sslip.io"

    static let apiOrigin = normalized(
        env("KLIC_API_ORIGIN")
            ?? info("KLIC_API_ORIGIN")
            ?? productionAPIOrigin
    )

    static let socketOrigin = normalized(
        env("KLIC_SOCKET_ORIGIN")
            ?? info("KLIC_SOCKET_ORIGIN")
            ?? apiOrigin
    )

    static let apiBaseURL = URL(string: "\(apiOrigin)/api/v1")!

    /// Firebase Web API key for the Identity Toolkit REST endpoints used by account recovery
    /// (§18.2 "Forgot password?"). Read from env or Info.plist; nil when unset/placeholder so
    /// the recovery flow degrades gracefully until the key is provisioned.
    static var firebaseWebAPIKey: String? {
        guard let raw = env("FIREBASE_WEB_API_KEY") ?? info("FIREBASE_WEB_API_KEY") else { return nil }
        guard !raw.contains("$("), !raw.contains("YOUR_") else { return nil }
        return raw
    }

    static func avatarURL(forUserId userId: String) -> String {
        "\(apiOrigin)/api/v1/users/\(userId)/avatar"
    }

    private static func env(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func info(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalized(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
