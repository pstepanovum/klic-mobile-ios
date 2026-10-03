import Foundation

extension APIClient {
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

    /// Delete a conversation for everyone (admin-only for groups). Also the §16.5
    /// chat-list Delete and the §16.6 block-and-delete follow-up.
    func deleteConversation(conversationId: String) async throws -> EmptyResponse {
        try await delete("/conversations/\(conversationId)")
    }

    // MARK: Conversations / messaging

    func conversations() async throws -> [Conversation] {
        var list: [Conversation] = try await get("/conversations")
        let cipherIndices = list.indices.filter { list[$0].lastMessage?.kind == "CIPHERTEXT" }
        guard !cipherIndices.isEmpty else { return list }
        let materialized = await E2eeMessaging.shared.materializeAll(cipherIndices.map { list[$0].lastMessage! })
        for (offset, i) in cipherIndices.enumerated() { list[i].lastMessage = materialized[offset] }
        return list
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

    func conversationPrefs(conversationId: String) async throws -> ConversationPrefs {
        try await get("/conversations/\(conversationId)/prefs")
    }

    /// Partial update; a double-optional set to `.some(nil)` sends an explicit null (unmute).
    /// `pinned` (§16.5) stamps/clears the chat-list pin — only sent when provided so
    /// mute updates stay compatible with pre-§16.5 servers.
    @discardableResult
    func updateConversationPrefs(
        conversationId: String,
        messagesMutedUntil: String?? = nil,
        muteMentions: Bool? = nil,
        callsMutedUntil: String?? = nil,
        pinned: Bool? = nil
    ) async throws -> ConversationPrefs {
        var body: [String: Any] = [:]
        if let value = messagesMutedUntil { body["messagesMutedUntil"] = value ?? NSNull() }
        if let muteMentions { body["muteMentions"] = muteMentions }
        if let value = callsMutedUntil { body["callsMutedUntil"] = value ?? NSNull() }
        if let pinned { body["pinned"] = pinned }
        return try await put("/conversations/\(conversationId)/prefs", body: body)
    }
}
