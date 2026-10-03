import Foundation

enum APIError: Error {
    case server(message: String, status: Int)
    case decoding
    case noData

    /// Human-readable message to show the user.
    var userMessage: String {
        switch self {
        case .server(let message, _): return message
        case .decoding: return "Unexpected response from the server."
        case .noData: return "Couldn’t reach the server. Check your connection."
        }
    }
}

/// Thin async/await REST client for the Klic API. Injects the access token and
/// transparently refreshes it once on a 401.
actor APIClient {
    static let shared = APIClient()

    /// Uses Klic-specific runtime overrides (`KLIC_API_ORIGIN`, `KLIC_SOCKET_ORIGIN`) when present.
    static let baseURL = AppConfig.apiBaseURL

    private let session = URLSession.shared

    /// §13.15: attachment uploads run on their own session with a generous resource
    /// timeout — a multi-hundred-MB video on a slow connection must be allowed to
    /// finish (the server's upload presigns last 2h to match).
    let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120            // inactivity, resets on bytes sent
        config.timeoutIntervalForResource = 2 * 60 * 60   // whole-transfer ceiling
        return URLSession(configuration: config)
    }()

    /// Coalesces concurrent refreshes so a burst of 401s triggers exactly one
    /// rotation + retry instead of N competing rotations.
    private var refreshTask: Task<Bool, Never>?

    /// Cursor-paginated page shape shared by the new §8.2 list endpoints.
    struct Page<Item: Decodable>: Decodable {
        let items: [Item]
        let nextCursor: String?
    }

    // MARK: - Core

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: nil, authed: true)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], authed: Bool = true) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body, authed: Bool = true) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    func put<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "PUT", body: data, authed: true)
    }

    func put<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "PUT", body: data, authed: true)
    }

    func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "PATCH", body: data, authed: true)
    }

    func patch<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "PATCH", body: data, authed: true)
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "DELETE", body: nil, authed: true)
    }

    /// Same as `request` but returns the raw response body (WebAuthn options JSON is
    /// passed through to AuthenticationServices without a Decodable model).
    func rawRequest(
        _ path: String,
        method: String,
        body: Data?,
        authed: Bool
    ) async throws -> Data {
        guard let url = URL(string: Self.baseURL.absoluteString + path) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authed, let token = await validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.noData }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: Self.message(from: respData, status: http.statusCode), status: http.statusCode)
        }
        return respData
    }

    func request<T: Decodable>(
        _ path: String,
        method: String,
        body: Data?,
        authed: Bool,
        hasRetriedAuth: Bool = false
    ) async throws -> T {
        // Concatenate so query strings (`?username=…`) are preserved — appendingPathComponent
        // would percent-encode the `?` into the path and 404 the route.
        guard let url = URL(string: Self.baseURL.absoluteString + path) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        // Only bodied requests declare a JSON payload — a Content-Type header on an
        // empty-body POST/DELETE makes the server try (and fail) to parse a body.
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authed, let token = await validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (respData, resp) = try await session.data(for: req)
        // Data-usage accounting (§8.3): API traffic counts as "other", call signaling as "calls".
        DataUsageTracker.shared.record(
            type: path.hasPrefix("/calls") ? .calls : .other,
            sent: body?.count ?? 0,
            received: respData.count
        )
        guard let http = resp as? HTTPURLResponse else { throw APIError.noData }
        if authed, http.statusCode == 401, !hasRetriedAuth, await refreshAccessToken() {
            return try await request(
                path,
                method: method,
                body: body,
                authed: authed,
                hasRetriedAuth: true
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: Self.message(from: respData, status: http.statusCode), status: http.statusCode)
        }

        if respData.isEmpty, let empty = EmptyResponse() as? T { return empty }
        do { return try JSONDecoder().decode(T.self, from: respData) }
        catch { throw APIError.decoding }
    }

    /// Turn the server's error body into a readable sentence
    /// (`{error,issues:[{message}]}` for validation, or `{message}` otherwise).
    private static func message(from data: Data, status: Int) -> String {
        struct Issue: Decodable { let message: String }
        struct Body: Decodable { let message: String?; let issues: [Issue]? }
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            if let first = body.issues?.first { return first.message }
            if let message = body.message { return message }
        }
        return "Request failed (\(status))."
    }

    /// A non-expired access token, refreshing first if the current one is missing or
    /// stale. Returns whatever token we hold afterwards (nil only if refresh failed).
    private func validAccessToken() async -> String? {
        let token = TokenStore.accessToken
        if !AccessToken.isExpired(token) { return token }
        if TokenStore.refreshToken != nil { _ = await refreshAccessToken() }
        return TokenStore.accessToken
    }

    /// Exchange the refresh token for a fresh access token, at most one in flight, so a
    /// burst of expired requests triggers a single rotation. Returns `true` if we hold
    /// a valid access token afterwards.
    ///
    /// A `401` means the refresh token is genuinely dead → clear it and broadcast a
    /// sign-out. Any other failure (network/5xx/timeout) is transient: keep the tokens
    /// so the user stays signed in and we retry later.
    @discardableResult
    func refreshAccessToken() async -> Bool {
        if let inFlight = refreshTask { return await inFlight.value }
        let task = Task<Bool, Never> { await self.performRefresh() }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func performRefresh() async -> Bool {
        guard let refreshToken = TokenStore.refreshToken else { return false }
        do {
            let res = try await refresh(refreshToken: refreshToken)
            TokenStore.save(access: res.accessToken, refresh: res.refreshToken)
            return true
        } catch let APIError.server(_, status) where status == 401 {
            TokenStore.clear()
            await MainActor.run { NotificationCenter.default.post(name: .klicSessionExpired, object: nil) }
            return false
        } catch {
            return false
        }
    }
}

struct EmptyResponse: Decodable {}
