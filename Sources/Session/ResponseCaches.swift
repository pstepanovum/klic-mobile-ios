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
        NotificationCenter.default.publisher(for: .klicSessionExpired)
            .sink { [weak self] _ in
                self?.conversations = []
                self?.loaded = false
                ChatCaches.clear()
            }
            .store(in: &cancellables)
    }

    /// Fetch the list from the server; keeps the cached copy on failure.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let list = try? await APIClient.shared.conversations() {
            conversations = list
            loaded = true
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
