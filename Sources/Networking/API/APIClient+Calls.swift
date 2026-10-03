import Foundation

extension APIClient {
    func recentCalls() async throws -> [RecentCall] { try await get("/calls") }

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
}
