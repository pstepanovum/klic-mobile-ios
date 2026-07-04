import Foundation
import Combine

// MARK: - Conversations store (§9.9)

/// In-memory conversations cache. The Chats tab (and "groups in common" on friend
/// profiles) renders instantly from `conversations` while `refresh()` reconciles with
/// the server in the background. Socket events stay authoritative between fetches:
/// message:new updates the row preview and reorders, `conversation:removed` drops the
/// chat the moment this user is removed from a group (§9.3).
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    private(set) var loaded = false
    private var refreshing = false
    private var cancellables: Set<AnyCancellable> = []

    /// §16.5: local pin decisions (conversationId → chatPinnedAt or nil) that outrank
    /// the fetched list until the server confirms it persisted them — so a pin made
    /// against a pre-§16.5 server still survives refreshes for the session.
    private var pinOverrides: [String: String?] = [:]

    private var myUserId: String? { AccessToken.subject(of: TokenStore.accessToken) }

    private init() {
        let socket = SocketService.shared
        socket.$lastMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.apply(message) }
            .store(in: &cancellables)
        socket.$lastConversationRemoved
            .compactMap { $0 }
            .sink { [weak self] conversationId in self?.remove(conversationId: conversationId) }
            .store(in: &cancellables)
        // §16.4: an edited message refreshes the row preview in place (no reorder).
        socket.$lastUpdatedMessage
            .compactMap { $0 }
            .sink { [weak self] message in self?.applyUpdated(message) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .klicSessionExpired)
            .sink { [weak self] _ in
                self?.conversations = []
                self?.loaded = false
                self?.pinOverrides = [:]
                ChatCaches.clear()
            }
            .store(in: &cancellables)
    }

    /// Fetch the list from the server; keeps the cached copy on failure.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if var list = try? await APIClient.shared.conversations() {
            // §16.5: unconfirmed local pins outrank the payload.
            for i in list.indices {
                if let override = pinOverrides[list[i].id] { list[i].chatPinnedAt = override }
            }
            conversations = Self.pinSorted(list)
            loaded = true
            // §14.3: seed each group's shared theme for precedence resolution.
            for convo in list where convo.type == "GROUP" {
                ChatThemeStore.shared.setGroupTheme(convo.theme, for: convo.id)
            }
        }
    }

    /// Move the conversation to the top with the new preview; unread ticks up for
    /// other people's messages (the server count reconciles on the next refresh).
    private func apply(_ message: Message) {
        guard let idx = conversations.firstIndex(where: { $0.id == message.conversationId }) else {
            // Unknown conversation (e.g. just added to a group) — pull the fresh list.
            Task { await refresh() }
            return
        }
        var convo = conversations[idx]
        convo.lastMessage = message
        if message.senderId != myUserId, !message.isSystem {
            convo.unreadCount = (convo.unreadCount ?? 0) + 1
        }
        conversations.remove(at: idx)
        conversations.insert(convo, at: 0)
        // §16.5: pinned chats stay above the recency order.
        conversations = Self.pinSorted(conversations)
    }

    // MARK: §16.5 chat-list pins

    /// Pinned chats first (newest pin highest), the rest in their existing recency
    /// order. Stable for the unpinned block — element order is preserved.
    static func pinSorted(_ list: [Conversation]) -> [Conversation] {
        let pinned = list.filter(\.isChatPinned)
            .sorted { pinDate($0) > pinDate($1) }
        return pinned + list.filter { !$0.isChatPinned }
    }

    private static func pinDate(_ convo: Conversation) -> Date {
        convo.chatPinnedAt.flatMap(SocketService.parseDate) ?? .distantPast
    }

    /// Pin/unpin a chat (§16.5): optimistic — the row moves immediately — then
    /// persisted via PUT /conversations/:id/prefs {pinned}. A pre-§16.5 server
    /// rejects the key; the pin then lives locally for this session.
    func setPinned(conversationId: String, pinned: Bool) {
        let stamp = pinned ? ISO8601DateFormatter().string(from: Date()) : nil
        pinOverrides[conversationId] = .some(stamp)
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].chatPinnedAt = stamp
            conversations = Self.pinSorted(conversations)
        }
        Task {
            if let prefs = try? await APIClient.shared.updateConversationPrefs(
                conversationId: conversationId, pinned: pinned),
               (prefs.pinnedAt != nil) == pinned {
                // Persisted — the fetched list is authoritative again.
                pinOverrides[conversationId] = nil
            }
        }
    }

    /// §16.4: swap an edited message into the row preview WITHOUT reordering or
    /// bumping unread — only when it still is the conversation's last message.
    private func applyUpdated(_ message: Message) {
        guard let idx = conversations.firstIndex(where: { $0.id == message.conversationId }),
              conversations[idx].lastMessage?.id == message.id else { return }
        conversations[idx].lastMessage = message
    }

    /// Reflect a group's saved edits (title / description / cover) into the cached
    /// list row so the Chats tab updates in place (§10.1).
    func applyGroupDetails(_ details: GroupConversationDetails) {
        guard let idx = conversations.firstIndex(where: { $0.id == details.id }) else { return }
        conversations[idx].title = details.title
        conversations[idx].description = details.description
        conversations[idx].avatarUrl = details.avatarUrl
    }

    /// Opening a chat clears its badge locally (the server clears it via message:read).
    func clearUnread(conversationId: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].unreadCount = 0
    }

    func remove(conversationId: String) {
        conversations.removeAll { $0.id == conversationId }
        ChatCaches.drop(conversationId: conversationId)
    }
}

// MARK: - Page-level response caches (§9.9)

/// Plain in-memory caches keyed by conversation/user id so navigating back to a page
/// renders instantly while the fresh copy loads in the background. Socket-driven state
/// (the open chat's message array) remains the source of truth — these only seed
/// first paint.
@MainActor
enum ChatCaches {
    /// Newest page of a chat's messages, in display (oldest-first) order.
    static var messagePages: [String: [Message]] = [:]
    static var groupDetails: [String: GroupConversationDetails] = [:]
    static var profiles: [String: UserProfile] = [:]
    static var attachments: [String: [ConversationAttachment]] = [:]
    static var starred: [String: [Message]] = [:]
    static var friends: [User] = []

    static func drop(conversationId: String) {
        messagePages[conversationId] = nil
        groupDetails[conversationId] = nil
        attachments[conversationId] = nil
        starred[conversationId] = nil
    }

    static func clear() {
        messagePages = [:]
        groupDetails = [:]
        profiles = [:]
        attachments = [:]
        starred = [:]
        friends = []
    }
}
