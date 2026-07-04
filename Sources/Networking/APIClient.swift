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
    private let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120            // inactivity, resets on bytes sent
        config.timeoutIntervalForResource = 2 * 60 * 60   // whole-transfer ceiling
        return URLSession(configuration: config)
    }()

    /// Coalesces concurrent refreshes so a burst of 401s triggers exactly one
    /// rotation + retry instead of N competing rotations.
    private var refreshTask: Task<Bool, Never>?

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

    // MARK: Friends

    func findUser(username: String) async throws -> [User] {
        let q = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        return try await get("/users?username=\(q)")
    }

    func friends() async throws -> [User] { try await get("/friends") }

    func friendRequests() async throws -> [FriendRequest] { try await get("/friends/requests") }

    func sendFriendRequest(userId: String) async throws -> EmptyResponse {
        try await post("/friends/requests", body: ["userId": userId])
    }

    func acceptFriendRequest(id: String) async throws -> EmptyResponse {
        try await post("/friends/requests/\(id)/accept", body: [:])
    }

    func declineFriendRequest(id: String) async throws -> EmptyResponse {
        try await post("/friends/requests/\(id)/decline", body: [:])
    }

    func openConversation(userId: String) async throws -> Conversation {
        try await post("/conversations", encodable: CreateConversationRequest(userId: userId, title: nil, userIds: nil))
    }

    func createGroupConversation(title: String, userIds: [String]) async throws -> Conversation {
        try await post(
            "/conversations",
            encodable: CreateConversationRequest(userId: nil, title: title, userIds: userIds)
        )
    }

    func conversationDetails(id: String) async throws -> GroupConversationDetails {
        try await get("/conversations/\(id)")
    }

    func updateGroupConversation(
        id: String,
        title: String? = nil,
        description: String?? = nil,
        avatarKey: String?? = nil
    ) async throws -> GroupConversationDetails {
        try await patch(
            "/conversations/\(id)",
            encodable: UpdateGroupConversationRequest(title: title, description: description, avatarKey: avatarKey)
        )
    }

    /// §14.3: set or clear the group's SHARED theme (admin-only; null clears).
    func updateGroupTheme(conversationId: String, theme: GroupThemePayload?) async throws -> GroupConversationDetails {
        var body: [String: Any] = [:]
        if let theme {
            var dict: [String: Any] = ["pattern": theme.pattern, "patternOpacity": theme.patternOpacity]
            if let gradientId = theme.gradientId { dict["gradientId"] = gradientId }
            if let intensity = theme.gradientIntensity { dict["gradientIntensity"] = intensity }
            if let bubble = theme.bubbleColorId { dict["bubbleColorId"] = bubble }
            body["theme"] = dict
        } else {
            body["theme"] = NSNull()
        }
        return try await patch("/conversations/\(conversationId)", body: body)
    }

    /// §14.3: hand the group admin role to another member (current admin only).
    func transferGroupAdmin(conversationId: String, userId: String) async throws -> GroupConversationDetails {
        try await post("/conversations/\(conversationId)/transfer-admin", body: ["userId": userId])
    }

    func requestGroupAvatarUpload(conversationId: String, contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/conversations/\(conversationId)/avatar-upload", body: ["contentType": contentType, "byteSize": byteSize])
    }

    func addGroupMembers(conversationId: String, userIds: [String]) async throws -> GroupConversationDetails {
        try await post("/conversations/\(conversationId)/members", body: ["userIds": userIds])
    }

    func leaveGroup(conversationId: String) async throws -> EmptyResponse {
        try await post("/conversations/\(conversationId)/leave", body: [:])
    }

    /// Admin-only: remove a member from a group (WP-S3, 204). Body-less DELETE — no
    /// Content-Type header, or Fastify 400s trying to parse an empty JSON body.
    func removeGroupMember(conversationId: String, userId: String) async throws {
        let _: EmptyResponse = try await delete("/conversations/\(conversationId)/members/\(userId)")
    }

    func deleteGroup(conversationId: String) async throws -> EmptyResponse {
        try await delete("/conversations/\(conversationId)")
    }

    // MARK: Reports (§12.1)

    /// File a safety/problem report. Exactly one of `targetUserId`/`messageId`, or
    /// neither (a target-less report = app/system problem report). 201 → {id}.
    func submitReport(
        targetUserId: String? = nil,
        messageId: String? = nil,
        category: String,
        details: String? = nil
    ) async throws -> CreatedReport {
        var body: [String: Any] = ["category": category]
        if let targetUserId { body["targetUserId"] = targetUserId }
        if let messageId { body["messageId"] = messageId }
        if let details, !details.isEmpty { body["details"] = details }
        return try await post("/reports", body: body)
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

    // MARK: Blocks (§10.4)

    func blockedUsers() async throws -> [BlockedUser] { try await get("/blocks") }

    func blockUser(userId: String) async throws -> EmptyResponse {
        try await post("/blocks", body: ["userId": userId])
    }

    func unblockUser(userId: String) async throws {
        let _: EmptyResponse = try await delete("/blocks/\(userId)")
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

    // MARK: Contacts sync (§10.4)

    func uploadContactHashes(_ hashes: [String]) async throws -> EmptyResponse {
        try await post("/me/contacts", body: ["hashes": hashes])
    }

    func deleteSyncedContacts() async throws {
        let _: EmptyResponse = try await delete("/me/contacts")
    }

    // MARK: Account deletion (§10.4)

    func setDeleteIfAway(months: Int?) async throws -> User {
        try await patch("/me", body: ["deleteIfAwayMonths": months ?? NSNull()])
    }

    func deleteAccount() async throws {
        let _: EmptyResponse = try await delete("/me")
    }

    // MARK: Conversations / messaging

    func conversations() async throws -> [Conversation] {
        var list: [Conversation] = try await get("/conversations")
        for i in list.indices where list[i].lastMessage?.kind == "CIPHERTEXT" {
            list[i].lastMessage = await E2eeMessaging.shared.materialize(list[i].lastMessage!)
        }
        return list
    }

    func messages(conversationId: String, before: String? = nil, limit: Int = 50) async throws -> [Message] {
        let raw: [Message] = try await rawMessages(conversationId: conversationId, before: before, limit: limit)
        return await E2eeMessaging.shared.materializeAll(raw)
    }

    private func rawMessages(conversationId: String, before: String? = nil, limit: Int = 50) async throws -> [Message] {
        var path = "/conversations/\(conversationId)/messages?limit=\(limit)"
        if let before, let encoded = before.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&before=\(encoded)"
        }
        return try await get(path)
    }

    func send(conversationId: String, body: String, replyToId: String? = nil) async throws -> Message {
        if E2eeConfig.sendEnabled {
            // Reply quotes travel inside the ciphertext at the cutover; the
            // plaintext replyToId is dropped then. Dormant until the flag flips.
            return try await E2eeMessaging.shared.sendText(conversationId: conversationId, text: body)
        }
        return try await sendLegacy(conversationId: conversationId, body: body, replyToId: replyToId)
    }

    private func sendLegacy(conversationId: String, body: String, replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = ["body": body]
        if let replyToId { payload["replyToId"] = replyToId }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    func sendSticker(conversationId: String, stickerId: String, replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = ["stickerId": stickerId]
        if let replyToId { payload["replyToId"] = replyToId }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    /// Toggle an emoji reaction on a message; returns the message's new aggregate.
    @discardableResult
    func react(conversationId: String, messageId: String, emoji: String) async throws -> [Reaction] {
        struct R: Decodable { let reactions: [Reaction] }
        let r: R = try await post("/conversations/\(conversationId)/messages/\(messageId)/reactions",
                                  body: ["emoji": emoji])
        return r.reactions
    }

    /// Delete a message for everyone (sender-only server-side).
    func deleteForEveryone(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await delete("/conversations/\(conversationId)/messages/\(messageId)?scope=everyone")
    }

    /// Edit a message's body/caption (§16.4). Sender-only, ≤48h server-side; returns
    /// the full refreshed message (`editedAt` set unless the body was identical).
    func editMessage(conversationId: String, messageId: String, body: String) async throws -> Message {
        try await patch("/conversations/\(conversationId)/messages/\(messageId)", body: ["body": body])
    }

    /// Pin a message (§16.3). DIRECT → either participant; GROUP → admin only.
    /// `notify: true` additionally fans out a SYSTEM "pinned a message" line.
    func pinMessage(conversationId: String, messageId: String, notify: Bool) async throws {
        let _: EmptyResponse = try await post(
            "/conversations/\(conversationId)/messages/\(messageId)/pin", body: ["notify": notify])
    }

    /// Unpin a message (§16.3). Same permission as pin; idempotent.
    func unpinMessage(conversationId: String, messageId: String) async throws {
        let _: EmptyResponse = try await delete("/conversations/\(conversationId)/messages/\(messageId)/pin")
    }

    /// The conversation's pinned messages, oldest→newest (§16.3). Decoded from the
    /// details payload through a minimal envelope so it works for DMs and groups
    /// alike (and degrades to [] against servers without pin support).
    func pinnedMessages(conversationId: String) async throws -> [ReplyPreview] {
        struct Envelope: Decodable { var pinnedMessages: [ReplyPreview]? }
        let envelope: Envelope = try await get("/conversations/\(conversationId)")
        return envelope.pinnedMessages ?? []
    }

    func recentCalls() async throws -> [RecentCall] { try await get("/calls") }

    func stickers() async throws -> [Sticker] {
        struct Catalog: Decodable { let stickers: [Sticker] }
        let catalog: Catalog = try await get("/stickers")
        return catalog.stickers
    }

    func startCall(conversationId: String, kind: String) async throws -> CallSession {
        try await post("/calls", body: ["conversationId": conversationId, "kind": kind])
    }

    /// The conversation's in-progress call, if any (404 when there is none).
    func activeCall(conversationId: String) async throws -> ActiveCallInfo {
        try await get("/conversations/\(conversationId)/active-call")
    }

    func joinToken(callId: String) async throws -> CallSession {
        try await post("/calls/\(callId)/token", body: [:])
    }

    func mediaJoined(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/media-joined", body: [:])
    }

    func declineCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/decline", body: [:])
    }

    func cancelCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/cancel", body: [:])
    }

    func failCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/fail", body: [:])
    }

    func endCall(callId: String) async throws -> EmptyResponse {
        try await post("/calls/\(callId)/end", body: [:])
    }

    nonisolated static func mobileDiagnostic(event: String, callId: String? = nil, detail: String? = nil) {
        guard let url = URL(string: baseURL.absoluteString + "/diagnostics/mobile-event") else { return }
        var body: [String: Any] = ["source": "ios", "event": event]
        if let callId { body["callId"] = callId }
        if let detail { body["detail"] = String(detail.prefix(500)) }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    func registerDevice(pushToken: String?, voipToken: String?) async throws -> EmptyResponse {
        var body: [String: Any] = ["platform": "IOS"]
        if let pushToken { body["pushToken"] = pushToken }
        if let voipToken { body["voipToken"] = voipToken }
        return try await post("/me/devices", body: body)
    }

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

    // MARK: Attachments / media

    /// Step 1: ask the server for a presigned PUT URL for an attachment.
    func requestUpload(conversationId: String, kind: String, contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/uploads", body: [
            "conversationId": conversationId, "kind": kind, "contentType": contentType, "byteSize": byteSize,
        ])
    }

    /// Step 2: PUT the bytes straight to object storage. No auth header; the
    /// Content-Type MUST equal what `requestUpload` was given or the URL's signature fails.
    func uploadData(_ data: Data, to uploadUrl: String, contentType: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await uploadSession.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: data.count, received: 0
        )
    }

    /// Step 2 with byte-level progress (§9.1): same contract as `uploadData`, plus a
    /// 0…1 callback driven by URLSession's didSendBodyData task delegate. The callback
    /// fires on a URLSession queue — callers hop to the main actor themselves.
    func uploadData(
        _ data: Data, to uploadUrl: String, contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (_, resp) = try await uploadSession.upload(for: req, from: data, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: data.count, received: 0
        )
    }

    /// Step 2, streamed from disk (§13.15): PUT a FILE's bytes without ever loading
    /// them into memory — URLSession streams uploadTask(fromFile:) chunk by chunk.
    /// Same progress contract as the Data variant.
    func uploadFile(
        _ fileURL: URL, to uploadUrl: String, contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (_, resp) = try await uploadSession.upload(for: req, fromFile: fileURL, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: size, received: 0
        )
    }

    /// Step 3: send the message referencing the uploaded object key(s).
    func sendMessage(conversationId: String, body: String?, attachments: [AttachmentDraft], replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = [:]
        if let body, !body.isEmpty { payload["body"] = body }
        if let replyToId { payload["replyToId"] = replyToId }
        payload["attachments"] = attachments.map { a -> [String: Any] in
            var d: [String: Any] = ["key": a.key, "kind": a.kind, "contentType": a.contentType, "byteSize": a.byteSize]
            if let w = a.width { d["width"] = w }
            if let h = a.height { d["height"] = h }
            if let ms = a.durationMs { d["durationMs"] = ms }
            if let wf = a.waveform { d["waveform"] = wf.base64EncodedString() }
            if let n = a.fileName { d["fileName"] = n }
            return d
        }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    /// Re-presign a download URL when an old attachment's link has expired.
    func refreshAttachmentURL(id: String) async throws -> String {
        struct R: Decodable { let url: String }
        let r: R = try await get("/attachments/\(id)/url")
        return r.url
    }

    /// Cursor-paginated page shape shared by the new §8.2 list endpoints.
    struct Page<Item: Decodable>: Decodable {
        let items: [Item]
        let nextCursor: String?
    }

    /// All of a conversation's attachments, newest-first (drives "Media, links, docs").
    func conversationAttachments(
        conversationId: String, kind: String? = nil, cursor: String? = nil, limit: Int = 60
    ) async throws -> Page<ConversationAttachment> {
        var path = "/conversations/\(conversationId)/attachments?limit=\(limit)"
        if let kind { path += "&kind=\(kind)" }
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        return try await get(path)
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

    func conversationPrefs(conversationId: String) async throws -> ConversationPrefs {
        try await get("/conversations/\(conversationId)/prefs")
    }

    /// Partial update; a double-optional set to `.some(nil)` sends an explicit null (unmute).
    @discardableResult
    func updateConversationPrefs(
        conversationId: String,
        messagesMutedUntil: String?? = nil,
        muteMentions: Bool? = nil,
        callsMutedUntil: String?? = nil
    ) async throws -> ConversationPrefs {
        var body: [String: Any] = [:]
        if let value = messagesMutedUntil { body["messagesMutedUntil"] = value ?? NSNull() }
        if let muteMentions { body["muteMentions"] = muteMentions }
        if let value = callsMutedUntil { body["callsMutedUntil"] = value ?? NSNull() }
        return try await put("/conversations/\(conversationId)/prefs", body: body)
    }

    /// Both star routes answer 204 with no body — send a body-less request (no
    /// Content-Type header), same as the other empty-payload routes.
    func starMessage(id: String) async throws {
        let _: EmptyResponse = try await request("/messages/\(id)/star", method: "POST", body: nil, authed: true)
    }

    func unstarMessage(id: String) async throws {
        let _: EmptyResponse = try await delete("/messages/\(id)/star")
    }

    /// Starred messages (message payloads + §14.4 sender/conversation enrichment),
    /// optionally scoped to one chat.
    func starredMessages(
        conversationId: String? = nil, cursor: String? = nil, limit: Int = 50
    ) async throws -> (items: [StarredMessageItem], nextCursor: String?) {
        var path = "/me/starred?limit=\(limit)"
        if let conversationId { path += "&conversationId=\(conversationId)" }
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        let page: Page<StarredMessageItem> = try await get(path)
        let materialized = await E2eeMessaging.shared.materializeAll(page.items.map(\.message))
        let items = zip(page.items, materialized).map { item, message in
            StarredMessageItem(message: message, sender: item.sender, conversation: item.conversation)
        }
        return (items, page.nextCursor)
    }

    // MARK: - E2EE key distribution (E2EE.md §6.2)

    func publishKeys(_ body: PublishKeysRequest) async throws -> PublishKeysResponse {
        try await put("/keys", encodable: body)
    }

    func preKeyCount(installId: String) async throws -> PreKeyCountResponse {
        try await get("/keys/count?installId=\(installId)")
    }

    func topUpPreKeys(_ body: TopUpPreKeysRequest) async throws -> EmptyResponse {
        try await post("/keys/prekeys", encodable: body)
    }

    func rotateSignedPreKey(_ body: RotateSignedPreKeyRequest) async throws -> EmptyResponse {
        try await put("/keys/signed-prekey", encodable: body)
    }

    func userKeys(userId: String) async throws -> UserKeysResponse {
        try await get("/users/\(userId)/keys")
    }

    func conversationDevices(conversationId: String) async throws -> DeviceDirectoryResponse {
        try await get("/conversations/\(conversationId)/devices")
    }

    func sendCiphertext(conversationId: String, body: CipherSendRequest) async throws -> Message {
        try await post("/conversations/\(conversationId)/messages", encodable: body)
    }

    // MARK: - Core

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", body: nil, authed: true)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authed: Bool = true) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body, authed: Bool = true) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "POST", body: data, authed: authed)
    }

    private func put<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "PUT", body: data, authed: true)
    }

    private func put<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "PUT", body: data, authed: true)
    }

    private func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path, method: "PATCH", body: data, authed: true)
    }

    private func patch<T: Decodable, Body: Encodable>(_ path: String, encodable body: Body) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path, method: "PATCH", body: data, authed: true)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "DELETE", body: nil, authed: true)
    }

    /// Same as `request` but returns the raw response body (WebAuthn options JSON is
    /// passed through to AuthenticationServices without a Decodable model).
    private func rawRequest(
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

    private func request<T: Decodable>(
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
        if !AccessToken.isExpired(TokenStore.accessToken) { return TokenStore.accessToken }
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

/// Task delegate that surfaces upload progress as sent-bytes fractions (§9.1).
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
