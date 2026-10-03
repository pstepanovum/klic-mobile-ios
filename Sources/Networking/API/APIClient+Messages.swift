import Foundation

extension APIClient {
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

    func stickers() async throws -> [Sticker] {
        struct Catalog: Decodable { let stickers: [Sticker] }
        let catalog: Catalog = try await get("/stickers")
        return catalog.stickers
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

    // MARK: Message search (§18.4)

    /// Global full-text search across every conversation the caller is a member of.
    func searchMessages(query: String, limit: Int = 30, cursor: String? = nil) async throws -> GlobalSearchResponse {
        var path = "/search/messages?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=\(limit)"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        return try await get(path)
    }

    /// In-chat search scoped to one conversation — returns match ids + timestamps for jump-to.
    func searchMessagesInConversation(
        conversationId: String, query: String, limit: Int = 30, cursor: String? = nil
    ) async throws -> ScopedSearchResponse {
        var path = "/conversations/\(conversationId)/messages/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=\(limit)"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        return try await get(path)
    }
}
