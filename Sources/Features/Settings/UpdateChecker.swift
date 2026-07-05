import SwiftUI

/// §14.7 / §20.2: checks the PUBLIC GitHub "latest release" against the running
/// `CFBundleShortVersionString` using a numeric SEMVER comparison (0.6.10 > 0.6.4 —
/// never a string compare).
///
/// Two entry points share one fetch:
///  - `checkIfDue()` — launch/foreground, throttled to once per 6h, only raises the
///    dismissible full-screen nag (`available`) when a NEWER release exists.
///  - `checkNow(force:)` — the Settings → Updates page. Drives `status` so the page can
///    show "checking / up to date / update available / offline / rate-limited / failed".
///    The manual button forces a fetch; opening the page auto-checks once (throttled so
///    re-opening doesn't hammer the API).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct ReleaseInfo: Identifiable, Equatable {
        let version: String
        let url: URL
        let notes: String?
        var id: String { version }
    }

    /// Drives the Settings → Updates page.
    enum CheckStatus: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(ReleaseInfo)
        case offline
        case rateLimited
        case failed
    }

    /// Newer release → dismissible full-screen nag (auth styling).
    @Published var available: ReleaseInfo?
    /// Result of the most recent Updates-page check.
    @Published var status: CheckStatus = .idle

    private static let releaseAPI = URL(string: "https://api.github.com/repos/pstepanovum/klic-mobile-ios/releases/latest")!
    /// GitHub's REST API rejects requests without a User-Agent (403). URLSession sets a
    /// default one, but pinning our own makes the check reliable across OS versions.
    private static let userAgent = "Klic-iOS-UpdateCheck"
    private static let nagInterval: TimeInterval = 6 * 60 * 60
    /// Re-opening the Updates page inside this window reuses the last result instead of
    /// refetching, so bouncing in and out doesn't hammer the API.
    private static let pageAutoInterval: TimeInterval = 5 * 60
    private static let lastCheckKey = "klic.update.lastCheckAt"

    private var inFlight = false
    private var lastPageAutoCheck: Date?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Launch / foreground nag

    /// No-op inside the 6h window, so a dismissed page stays dismissed until the next due
    /// check finds the (same or a newer) release.
    func checkIfDue() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let elapsed = Date().timeIntervalSince1970 - lastCheck
        guard lastCheck == 0 || elapsed >= Self.nagInterval else { return }
        guard !inFlight else { return }
        Task { await runFetch { result in
            if case let .success(info?) = result,
               Self.isVersion(info.version, newerThan: self.currentVersion) {
                self.available = info
            }
        } }
    }

    func dismiss() {
        available = nil
    }

    // MARK: Updates page

    /// Called when the Updates page appears. Auto-checks once, but skips a refetch if we
    /// already have a fresh result (avoids hammering GitHub on every navigation).
    func checkOnAppear() {
        if let last = lastPageAutoCheck,
           Date().timeIntervalSince(last) < Self.pageAutoInterval,
           status != .idle, status != .checking {
            return
        }
        checkNow(force: false)
    }

    /// Manual "Check for updates" (force = true) always fetches; the on-appear auto-check
    /// (force = false) yields to an in-flight request but otherwise fetches.
    func checkNow(force: Bool) {
        guard !inFlight else { return }
        if !force { lastPageAutoCheck = Date() }
        status = .checking
        Task { await runFetch { result in
            if force { self.lastPageAutoCheck = Date() }
            switch result {
            case let .success(info):
                if let info, Self.isVersion(info.version, newerThan: self.currentVersion) {
                    self.status = .updateAvailable(info)
                    self.available = info
                } else {
                    self.status = .upToDate
                }
            case .offline:
                self.status = .offline
            case .rateLimited:
                self.status = .rateLimited
            case .failed:
                self.status = .failed
            }
        } }
    }

    // MARK: Fetch

    private enum FetchResult {
        /// Reachable + parsed. `nil` only when the tag couldn't be understood.
        case success(ReleaseInfo?)
        case offline
        case rateLimited
        case failed
    }

    /// Serializes fetches behind `inFlight`, records the 6h nag timestamp on any reachable
    /// response, then hands the typed result to `apply` on the main actor.
    private func runFetch(_ apply: @escaping (FetchResult) -> Void) async {
        inFlight = true
        defer { inFlight = false }
        let result = await Self.fetchLatest()
        switch result {
        case .success, .rateLimited:
            // We reached GitHub — reset the nag throttle even on a rate-limit so we back off.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        case .offline, .failed:
            break
        }
        apply(result)
    }

    private static func fetchLatest() async -> FetchResult {
        struct Release: Decodable {
            let tagName: String
            let htmlUrl: String
            let body: String?
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name", htmlUrl = "html_url", body
            }
        }

        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where offlineCodes.contains(error.code) {
            return .offline
        } catch {
            return .failed
        }

        guard let http = response as? HTTPURLResponse else { return .failed }
        // 403 (unauthenticated rate limit) / 429 (secondary limit) — back off, don't nag.
        if http.statusCode == 403 || http.statusCode == 429 { return .rateLimited }
        guard http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .failed
        }

        let latest = normalizedVersion(from: release.tagName)
        guard !latest.isEmpty, let url = URL(string: release.htmlUrl) else {
            return .success(nil)
        }
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ReleaseInfo(
            version: latest,
            url: url,
            notes: (notes?.isEmpty == false) ? notes : nil
        ))
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
    ]

    /// Strips a leading `v` and any `-beta`/`+build` suffix from a `vX.Y.Z` tag.
    private static func normalizedVersion(from tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Keep only the numeric dotted core (drop "-beta.1", "+57", etc.).
        let core = s.prefix { $0.isNumber || $0 == "." }
        return String(core)
    }

    /// Numeric dotted-version comparison — compares each component as an Int so
    /// "0.6.10" > "0.6.4" (a string compare would get this wrong).
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
