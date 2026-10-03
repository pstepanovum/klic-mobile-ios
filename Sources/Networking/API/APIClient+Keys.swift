import Foundation

extension APIClient {
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
}
