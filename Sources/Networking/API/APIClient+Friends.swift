import Foundation

extension APIClient {
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

    /// §16.6: remove an accepted friendship (404 when there is none). The DM
    /// conversation and its history remain. Body-less DELETE — no Content-Type header.
    func removeFriend(userId: String) async throws {
        let _: EmptyResponse = try await delete("/friends/\(userId)")
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

    // MARK: Blocks (§10.4)

    func blockedUsers() async throws -> [BlockedUser] { try await get("/blocks") }

    func blockUser(userId: String) async throws -> EmptyResponse {
        try await post("/blocks", body: ["userId": userId])
    }

    func unblockUser(userId: String) async throws {
        let _: EmptyResponse = try await delete("/blocks/\(userId)")
    }

    // MARK: Contacts sync (§10.4)

    func uploadContactHashes(_ hashes: [String]) async throws -> EmptyResponse {
        try await post("/me/contacts", body: ["hashes": hashes])
    }

    func deleteSyncedContacts() async throws {
        let _: EmptyResponse = try await delete("/me/contacts")
    }
}
