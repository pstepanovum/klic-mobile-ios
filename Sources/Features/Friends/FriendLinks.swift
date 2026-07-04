import Foundation

/// §13.8: friend links on the web surface — https://klic.pstepanov.dev/u/<username>
/// (plus the /add alias). Parses QR payloads and incoming universal links, and routes
/// the username into the add-friend flow: RootView switches to the Friends tab and
/// FriendsView opens its add-friend sheet prefilled. AltStore builds may lack the
/// applinks entitlement — then universal links simply never reach the app (silent
/// degradation); in-app QR scanning keeps working regardless.
@MainActor
final class FriendLinkRouter: ObservableObject {
    static let shared = FriendLinkRouter()

    /// Username awaiting the add-friend flow; consumed (and cleared) by FriendsView.
    @Published var pendingUsername: String?

    static let linkHost = "klic.pstepanov.dev"

    /// Handle an incoming URL; true when it was a Klic friend link.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let username = Self.username(fromLink: url) else { return false }
        pendingUsername = username
        return true
    }

    /// https://klic.pstepanov.dev/u/<name> or /add/<name>; legacy klic.app links
    /// (the old QR payload) stay accepted for back-compat.
    static func username(fromLink url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == linkHost || host.hasSuffix("klic.app") else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, ["u", "add"].contains(parts[1].lowercased()) else { return nil }
        let name = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : name
    }

    /// Any scanned QR payload: the URL forms above, or the legacy raw "@username".
    static func username(fromScannedCode code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let name = username(fromLink: url) { return name }
        if trimmed.hasPrefix("@"), trimmed.count > 1 {
            return String(trimmed.dropFirst()).lowercased()
        }
        return nil
    }

    /// The link this user's QR code encodes (§13.8).
    static func link(forUsername username: String) -> String {
        "https://\(linkHost)/u/\(username)"
    }
}
