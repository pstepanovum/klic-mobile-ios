import SwiftUI

/// Loading, sending, reacting to, and deleting messages, plus typing/read-receipt signaling.
extension ChatView {
    // Advance the ticks on the user's own messages when a receipt arrives.
    func applyReceipt(_ receipt: SocketService.Receipt, status: String) {
        guard receipt.conversationId == conversation.id, receipt.userId != myId else { return }
        for i in messages.indices where messages[i].senderId == myId {
            guard let created = SocketService.parseDate(messages[i].createdAt), created <= receipt.at else { continue }
            if status == "read" { messages[i].status = "read" }
            else if messages[i].status != "read" { messages[i].status = "delivered" }
        }
    }

    func react(_ message: Message, emoji: String) async {
        if let updated = try? await APIClient.shared.react(
            conversationId: conversation.id, messageId: message.id, emoji: emoji),
           let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].reactions = updated
        }
    }

    func deleteForMe(_ message: Message) {
        hiddenIds.insert(message.id)
        Self.saveHidden(hiddenIds, conversation.id)
    }

    func deleteEveryone(_ message: Message) async {
        try? await APIClient.shared.deleteForEveryone(conversationId: conversation.id, messageId: message.id)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].deletedAt = ISO8601DateFormatter().string(from: Date())
            messages[idx].reactions = []
        }
    }

    /// Throttled typing signal — re-sent at most every 2s while typing, cleared on stop.
    func emitTyping(_ isTyping: Bool) {
        if isTyping {
            let now = Date()
            guard now.timeIntervalSince(lastTypingSent) > 2 else { return }
            lastTypingSent = now
            socket.emit("typing", ["conversationId": conversation.id, "isTyping": true])
        } else {
            lastTypingSent = .distantPast
            socket.emit("typing", ["conversationId": conversation.id, "isTyping": false])
        }
    }

    func previewText(for message: Message) -> String {
        if !message.body.isEmpty { return message.body }
        if message.isSticker { return "Sticker" }
        if let a = message.attachments.first {
            switch a.kind {
            case "IMAGE": return "Photo"
            case "VOICE": return "Voice message"
            case "VIDEO": return "Video"
            default:      return "File"
            }
        }
        if message.isCallEvent { return message.call?.isVideo == true ? "Video call" : "Voice call" }
        return "Message"
    }

    private static func hiddenKey(_ convId: String) -> String { "hiddenMessages.\(convId)" }
    static func loadHidden(_ convId: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey(convId)) ?? [])
    }
    static func saveHidden(_ ids: Set<String>, _ convId: String) {
        UserDefaults.standard.set(Array(ids), forKey: hiddenKey(convId))
    }

    func upsert(_ msg: Message) {
        if let idx = messages.firstIndex(where: { $0.id == msg.id }) { messages[idx] = msg }
        else { messages.append(msg) }
    }

    func load() async {
        let batch = (try? await APIClient.shared.messages(conversationId: conversation.id)) ?? []
        messages = batch.reversed()
        hasMore = batch.count >= 50
        markRead()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, initialLoadDone else { return }
        isLoadingMore = true
        let anchorId = messages.first?.id
        let before = messages.first?.createdAt
        let batch = (try? await APIClient.shared.messages(conversationId: conversation.id, before: before)) ?? []
        messages.insert(contentsOf: batch.reversed(), at: 0)
        hasMore = batch.count >= 50
        isLoadingMore = false
        if let anchorId {
            DispatchQueue.main.async { scrollProxy?.scrollTo(anchorId, anchor: .top) }
        }
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        let replyId = replyingTo?.id
        draft = ""
        withAnimation { replyingTo = nil }
        if let msg = try? await APIClient.shared.send(conversationId: conversation.id, body: body, replyToId: replyId) {
            upsert(msg)
            scrollToBottom()
        }
    }

    func sendSticker(_ id: String) async {
        let replyId = replyingTo?.id
        withAnimation { replyingTo = nil }
        if let msg = try? await APIClient.shared.sendSticker(conversationId: conversation.id, stickerId: id, replyToId: replyId) {
            upsert(msg)
            scrollToBottom()
        }
    }

    func markRead() {
        socket.emit("message:read", ["conversationId": conversation.id])
    }
}
