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

    /// Star/unstar a message (POST/DELETE /messages/:id/star) with an optimistic
    /// local flip; try? so an undeployed server just leaves the local state.
    func toggleStar(_ message: Message) async {
        let newValue = !(message.starred ?? false)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].starred = newValue
        }
        if newValue {
            try? await APIClient.shared.starMessage(id: message.id)
        } else {
            try? await APIClient.shared.unstarMessage(id: message.id)
        }
    }

    /// Ensure a message is loaded (fetch-back pagination), then scroll to it.
    func jumpToMessage(_ id: String) async {
        var attempts = 0
        while !messages.contains(where: { $0.id == id }), hasMore, attempts < 20 {
            attempts += 1
            await loadMore()
        }
        guard messages.contains(where: { $0.id == id }) else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the list settle
        withAnimation(.easeOut(duration: 0.25)) {
            scrollProxy?.scrollTo(id, anchor: .center)
        }
    }

    /// §16.1/§16.3: scroll to a message and flash a brief tinted pulse on it.
    func jumpToMessageHighlighting(_ id: String) async {
        await jumpToMessage(id)
        guard messages.contains(where: { $0.id == id }) else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)   // let the scroll land
        withAnimation(.easeIn(duration: 0.15)) { highlightedMessageId = id }
        try? await Task.sleep(nanoseconds: 850_000_000)
        if highlightedMessageId == id {
            withAnimation(.easeOut(duration: 0.35)) { highlightedMessageId = nil }
        }
    }

    // MARK: - Edit (§16.4)

    /// Own, non-deleted TEXT/caption messages can be edited within 48h.
    func canEdit(_ message: Message) -> Bool {
        guard message.senderId == myId, !message.isDeleted else { return false }
        guard ["TEXT", "IMAGE", "VIDEO", "VOICE", "FILE", "VIDEO_NOTE"].contains(message.kind) else { return false }
        guard let created = SocketService.parseDate(message.createdAt) else { return false }
        return Date().timeIntervalSince(created) < 48 * 3600
    }

    /// Enter edit mode: stash the current draft, load the original body, focus.
    func beginEdit(_ message: Message) {
        draftBeforeEdit = draft
        withAnimation {
            replyingTo = nil
            editingMessage = message
        }
        draft = message.body
        isComposerFocused = true
    }

    /// Exit edit mode restoring whatever draft was in the composer before (§16.4).
    func exitEdit() {
        withAnimation { editingMessage = nil }
        draft = draftBeforeEdit
        draftBeforeEdit = ""
    }

    /// Apply the edit: empty → shake (no request), unchanged → silent exit,
    /// otherwise PATCH and swap the refreshed message in place.
    func applyEdit() async {
        guard let target = editingMessage else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            editShakeTrigger += 1
            return
        }
        if body == target.body {
            exitEdit()
            return
        }
        do {
            let updated = try await APIClient.shared.editMessage(
                conversationId: conversation.id, messageId: target.id, body: body)
            applyUpdatedMessage(updated)
        } catch {
            // Offline / pre-§16.4 server: keep the user's text on screen by leaving
            // edit mode without losing their draft.
        }
        exitEdit()
    }

    /// §16.4: merge a full refreshed payload in place — no scroll jump. The socket
    /// fan-out is per-conversation, not per-requester, so my star survives.
    func applyUpdatedMessage(_ updated: Message) {
        guard let idx = messages.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = updated
        merged.starred = merged.starred ?? messages[idx].starred
        messages[idx] = merged
    }

    // MARK: - Pins (§16.3)

    /// DIRECT → either participant may pin; GROUP → admin only.
    var canPinHere: Bool {
        isDirect || groupDetails?.isAdmin == true
    }

    func loadPinned() async {
        if let pinned = try? await APIClient.shared.pinnedMessages(conversationId: conversation.id) {
            setPinnedMessages(pinned)
        }
    }

    /// Replace the pinned list (oldest→newest) and reset the cycle cursor to the
    /// newest pin.
    func setPinnedMessages(_ pinned: [ReplyPreview]) {
        withAnimation(.easeInOut(duration: 0.2)) {
            pinnedMessages = pinned
            pinnedCursor = max(0, pinned.count - 1)
        }
    }

    func pin(_ message: Message, notify: Bool) async {
        do {
            try await APIClient.shared.pinMessage(
                conversationId: conversation.id, messageId: message.id, notify: notify)
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].pinnedAt = ISO8601DateFormatter().string(from: Date())
            }
            hiddenNewestPinId = nil
            await loadPinned()
        } catch {
            // Pre-§16.3 server — nothing to update.
        }
    }

    func unpin(messageId: String) async {
        try? await APIClient.shared.unpinMessage(conversationId: conversation.id, messageId: messageId)
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].pinnedAt = nil
        }
        setPinnedMessages(pinnedMessages.filter { $0.id != messageId })
    }

    /// §16.3: apply a realtime pin/unpin event — the chosen live mechanism (no
    /// conversation:updated refetch). Pins from others refresh the compact list.
    func handlePinEvent(_ event: SocketService.PinEvent) {
        if event.pinned {
            if let idx = messages.firstIndex(where: { $0.id == event.messageId }) {
                messages[idx].pinnedAt = ISO8601DateFormatter().string(from: Date())
            }
            hiddenNewestPinId = nil
            Task { await loadPinned() }
        } else {
            if let idx = messages.firstIndex(where: { $0.id == event.messageId }) {
                messages[idx].pinnedAt = nil
            }
            setPinnedMessages(pinnedMessages.filter { $0.id != event.messageId })
        }
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
            case "IMAGE":      return "Photo"
            case "VOICE":      return "Voice message"
            case "VIDEO":      return "Video"
            case "VIDEO_NOTE": return "Video message"
            default:           return "File"
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
        // §9.9: paint the cached newest page instantly, then reconcile with the server.
        if messages.isEmpty, let cached = ChatCaches.messagePages[conversation.id], !cached.isEmpty {
            messages = cached
            hasMore = cached.count >= 50
        }
        guard let batch = try? await APIClient.shared.messages(conversationId: conversation.id) else {
            markRead()
            return   // offline — keep whatever the cache painted
        }
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
            FrequentContacts.recordSend(conversationId: conversation.id)   // §10.4
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
        ConversationStore.shared.clearUnread(conversationId: conversation.id)
    }
}
