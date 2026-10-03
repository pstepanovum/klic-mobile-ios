import Foundation

extension APIClient {
    // MARK: Profile

    /// The current user's own profile (selfUser — includes §11.5 about/links and the
    /// §11.6 privacy fields on newer servers).
    func me() async throws -> User { try await get("/me") }

    /// Update the current user's profile (PATCH /me).
    func updateProfile(displayName: String? = nil, showLastSeen: Bool? = nil, avatarKey: String?? = nil) async throws -> User {
        var body: [String: Any] = [:]
        if let displayName { body["displayName"] = displayName }
        if let showLastSeen { body["showLastSeen"] = showLastSeen }
        if let avatarKey { body["avatarKey"] = avatarKey ?? NSNull() }  // nil-wrapped clears it
        return try await patch("/me", body: body)
    }

    /// Generic PATCH /me for the §11.4–§11.6 fields (username, about, links,
    /// visibility enums, silenceUnknownCallers, readReceipts). Returns selfUser.
    func updateMe(_ fields: [String: Any]) async throws -> User {
        try await patch("/me", body: fields)
    }

    /// Presign a PUT for a new avatar; upload the bytes via `uploadData`, then PATCH /me with the key.
    func requestAvatarUpload(contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/me/avatar-upload", body: ["contentType": contentType, "byteSize": byteSize])
    }

    /// A friend's profile (avatar, name, presence/last-seen if shared).
    func userProfile(id: String) async throws -> UserProfile {
        try await get("/users/\(id)")
    }

    /// Public, stable avatar URL for any user id (the endpoint 302-redirects to the
    /// presigned image, or 404s — in which case the UI falls back to initials).
    nonisolated static func avatarURL(forUserId id: String) -> String {
        AppConfig.avatarURL(forUserId: id)
    }

    func registerDevice(pushToken: String?, voipToken: String?) async throws -> EmptyResponse {
        // installId lets the server upsert ONE device row per install and merge the APNs +
        // VoIP tokens onto it, instead of racing parallel inserts that lose the VoIP token (H1).
        var body: [String: Any] = ["platform": "IOS", "installId": InstallIdentity.current]
        if let pushToken { body["pushToken"] = pushToken }
        if let voipToken { body["voipToken"] = voipToken }
        return try await post("/me/devices", body: body)
    }

    // MARK: Account deletion (§10.4)

    func setDeleteIfAway(months: Int?) async throws -> User {
        try await patch("/me", body: ["deleteIfAwayMonths": months ?? NSNull()])
    }

    func deleteAccount() async throws {
        let _: EmptyResponse = try await delete("/me")
    }

    // MARK: - Notification & conversation prefs, stars (CALLS.md §8.2)

    func notificationPrefs() async throws -> NotificationPrefs {
        try await get("/me/notification-prefs")
    }

    /// Partial update — only the provided toggles are sent.
    @discardableResult
    func updateNotificationPrefs(
        messages: Bool? = nil, groups: Bool? = nil, calls: Bool? = nil, friendRequests: Bool? = nil
    ) async throws -> NotificationPrefs {
        var body: [String: Any] = [:]
        if let messages { body["messages"] = messages }
        if let groups { body["groups"] = groups }
        if let calls { body["calls"] = calls }
        if let friendRequests { body["friendRequests"] = friendRequests }
        return try await put("/me/notification-prefs", body: body)
    }

    func resetNotificationPrefs() async throws {
        let _: EmptyResponse = try await delete("/me/notification-prefs")
    }
}
