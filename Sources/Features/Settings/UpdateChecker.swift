import SwiftUI

/// §14.7: checks the GitHub latest release against the running version on launch and
/// foreground, throttled to once per 6h (persisted timestamp). When a newer version
/// exists, `available` drives a DISMISSIBLE full-screen update page. Dismissing stops
/// the nagging until the next throttle window finds the (same or a newer) release.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct ReleaseInfo: Identifiable, Equatable {
        let version: String
        let url: URL
        let notes: String?
        var id: String { version }
    }

    @Published var available: ReleaseInfo?

    private static let releaseAPI = URL(string: "https://api.github.com/repos/pstepanovum/klic-mobile-ios/releases/latest")!
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let lastCheckKey = "klic.update.lastCheckAt"

    private var checking = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Launch/foreground entry point — no-op inside the 6h window, so a dismissed
    /// page stays dismissed until the next due check.
    func checkIfDue() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        guard lastCheck == 0 || elapsed >= Self.checkInterval else { return }
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            await check()
        }
    }

    func dismiss() {
        available = nil
    }

    private func check() async {
        struct Release: Decodable {
            let tagName: String
            let htmlUrl: String
            let body: String?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name", htmlUrl = "html_url", body
            }
        }
        var request = URLRequest(url: Self.releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            // Network/API failure — don't burn the throttle window; retry next trigger.
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard Self.isVersion(latest, newerThan: currentVersion),
              let url = URL(string: release.htmlUrl) else { return }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        available = ReleaseInfo(version: latest, url: url, notes: (notes?.isEmpty == false) ? notes : nil)
    }

    /// Numeric dotted-version comparison ("0.5.7" > "0.5.6").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
