import Foundation
import Security

/// Stable per-install identifier sent on every POST /me/devices so the server can key
/// device rows by (userId, platform, installId) and MERGE the APNs + VoIP tokens onto a
/// single row instead of racing parallel inserts — the root cause of the lost-VoIP-token
/// "callee never rings" bug (H1). Generated once and reused for the life of the install.
///
/// Stored in the Keychain (like TokenStore) so it survives app restarts and is readable
/// from a background/VoIP-push wake. Accessibility mirrors the token store's
/// after-first-unlock/this-device-only policy: a restored install re-registers under a
/// fresh id rather than inheriting another device's id.
enum InstallIdentity {
    private static let service = "com.klic.mobile.app.install"
    private static let account = "installId"

    /// The stable install id for this app installation.
    static var current: String {
        if let existing = read() { return existing }
        let id = UUID().uuidString
        write(id)
        return id
    }

    // MARK: - Keychain primitives

    private static func write(_ value: String) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
