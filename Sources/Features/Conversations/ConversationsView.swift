import SwiftUI
import Inject

struct ConversationsView: View {
    @ObserveInjection var inject
    /// §9.9: the shared store renders the cached list instantly and refreshes in the
    /// background; socket events keep it live (new previews, removed groups).
    @ObservedObject private var store = ConversationStore.shared
    @State private var searchText = ""
    @State private var showNewMessage = false
    @State private var navPath = NavigationPath()
    @State private var pendingConversation: Conversation?
    // §18.4: server-backed global message search (grouped by conversation).
    @State private var messageResults: [GlobalSearchResult] = []
    @State private var searchingMessages = false
    @State private var searchTask: Task<Void, Never>?
    // §16.5: chat-row long-press menu + its follow-up sheets.
    @State private var menuTarget: Conversation?
    @State private var muteSheetTarget: Conversation?
    @State private var deleteConfirmTarget: Conversation?
    @State private var actionError: String?

    private var conversations: [Conversation] { store.conversations }

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        let q = searchText.lowercased()
        return conversations.filter {
            conversationTitle($0).lowercased().contains(q) ||
            $0.members.contains {
                $0.displayName.lowercased().contains(q) ||
                $0.username.lowercased().contains(q)
            } ||
            ($0.lastMessage?.body.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Capsule search bar matching the Login inputs (§9.8).
                    KlicSearchField(placeholder: String(localized: "Search chats & messages"), text: $searchText)
                        .padding(.bottom, 6)

                    if isSearching {
                        sectionHeader(String(localized: "Chats"))
                    }
                    ForEach(filtered) { convo in
                        ConversationRow(conversation: convo)
                            .contentShape(Rectangle())
                            // §16.5: tap opens the chat; long-press opens the row menu
                            // (same split as message bubbles — a NavigationLink would
                            // still fire its push on the long-press release).
                            .onTapGesture { navPath.append(convo) }
                            .onLongPressGesture(minimumDuration: 0.3) {
                                withAnimation(.easeIn(duration: 0.15)) { menuTarget = convo }
                            }
                    }
                    if isSearching && filtered.isEmpty {
                        emptyHint(String(localized: "No chats match."))
                    }

                    // §18.4: message hits, grouped by conversation.
                    if isSearching {
                        messageResultsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Chats")
            .navigationDestination(for: Conversation.self) { ChatView(conversation: $0) }
            // §18.4: opening a global-search message hit jumps straight to that message.
            .navigationDestination(for: MessageJump.self) {
                ChatView(conversation: $0.conversation, initialJumpMessageId: $0.messageId)
            }
            .onChange(of: searchText) { _, q in scheduleGlobalSearch(q) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNewMessage = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showNewMessage, onDismiss: {
                if let convo = pendingConversation {
                    navPath.append(convo)
                    pendingConversation = nil
                }
            }) {
                NewMessageSheet { convo in
                    pendingConversation = convo
                    showNewMessage = false
                }
            }
            // §16.5: the chat-row long-press menu — same visual language as the
            // message long-press overlay.
            .overlay {
                if let target = menuTarget {
                    ConversationActionsOverlay(
                        conversation: target,
                        isMuted: ChatLocalPrefs.messagesMuted(target.id),
                        onMarkRead: {
                            markAsRead(target)
                            dismissRowMenu()
                        },
                        onTogglePin: {
                            store.setPinned(conversationId: target.id, pinned: !target.isChatPinned)
                            dismissRowMenu()
                        },
                        onMute: {
                            dismissRowMenu()
                            muteSheetTarget = target
                        },
                        onUnmute: {
                            applyMute(target.id, optionId: "off")
                            dismissRowMenu()
                        },
                        onDelete: {
                            dismissRowMenu()
                            deleteConfirmTarget = target
                        },
                        onDismiss: { dismissRowMenu() }
                    )
                    .transition(.opacity)
                }
            }
            // §16.5: mute durations — the existing per-chat options (§8.2 prefs).
            .klicSelectionSheet(
                isPresented: Binding(
                    get: { muteSheetTarget != nil },
                    set: { if !$0 { muteSheetTarget = nil } }
                ),
                title: String(localized: "Mute messages"),
                options: ChatNotificationsCard.muteOptions.filter { $0.id != "off" }
            ) { option in
                guard let target = muteSheetTarget else { return }
                muteSheetTarget = nil
                applyMute(target.id, optionId: option.id)
            }
            // §16.5: Delete — the existing delete-conversation flow with its confirm.
            .klicSelectionSheet(
                isPresented: Binding(
                    get: { deleteConfirmTarget != nil },
                    set: { if !$0 { deleteConfirmTarget = nil } }
                ),
                title: deleteConfirmTarget?.type == "GROUP"
                    ? String(localized: "Delete this group?")
                    : String(localized: "Delete this chat?"),
                message: deleteConfirmTarget?.type == "GROUP"
                    ? String(localized: "This removes the group chat and all of its messages for everyone.")
                    : String(localized: "This removes the chat and its messages."),
                options: [KlicSheetOption(
                    id: "delete",
                    label: deleteConfirmTarget?.type == "GROUP"
                        ? String(localized: "Delete Group")
                        : String(localized: "Delete Chat"),
                    isDestructive: true
                )]
            ) { _ in
                guard let target = deleteConfirmTarget else { return }
                deleteConfirmTarget = nil
                Task { await deleteConversation(target) }
            }
            .alert(
                String(localized: "Couldn't delete"),
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button(String(localized: "OK"), role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
        }
        .tint(KlicColor.primary)
        .enableInjection()
    }

    private func dismissRowMenu() {
        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
    }

    // MARK: §18.4 global message search

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Message hits grouped by conversation, preserving the server's most-recent-first order.
    private var groupedMessageResults: [(conversationId: String, title: String, avatarUrl: String?, hits: [GlobalSearchResult])] {
        var order: [String] = []
        var groups: [String: [GlobalSearchResult]] = [:]
        for r in messageResults {
            if groups[r.conversationId] == nil { order.append(r.conversationId) }
            groups[r.conversationId, default: []].append(r)
        }
        return order.map { id in
            let hits = groups[id] ?? []
            let title = hits.first?.conversationTitle
                ?? conversations.first { $0.id == id }.map(conversationTitle)
                ?? String(localized: "Chat")
            return (id, title, hits.first?.conversationAvatarUrl, hits)
        }
    }

    @ViewBuilder private var messageResultsSection: some View {
        HStack(spacing: 8) {
            sectionHeader(String(localized: "Messages"))
            if searchingMessages { ProgressView().controlSize(.small) }
            Spacer()
        }
        if !searchingMessages && messageResults.isEmpty {
            emptyHint(String(localized: "No messages match."))
        }
        ForEach(groupedMessageResults, id: \.conversationId) { group in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    AvatarView(url: group.avatarUrl, name: group.title, size: 28)
                    Text(group.title)
                        .font(KlicFont.medium(14))
                        .foregroundStyle(KlicColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

                ForEach(group.hits) { hit in
                    Button { openMessageHit(hit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if let sender = hit.senderName {
                                    Text(sender)
                                        .font(KlicFont.caption(11))
                                        .foregroundStyle(KlicColor.primary)
                                }
                                Spacer()
                                if let stamp = Self.stamp(hit.createdAt) {
                                    Text(stamp)
                                        .font(KlicFont.caption(11))
                                        .foregroundStyle(KlicColor.textMuted)
                                }
                            }
                            Text(Self.plainSnippet(hit.snippet))
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textPrimary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 6)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(KlicFont.caption(12).weight(.semibold))
            .foregroundStyle(KlicColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(KlicFont.body(14))
            .foregroundStyle(KlicColor.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private func openMessageHit(_ hit: GlobalSearchResult) {
        guard let convo = conversations.first(where: { $0.id == hit.conversationId }) else { return }
        navPath.append(MessageJump(conversation: convo, messageId: hit.messageId))
    }

    /// Debounce, then run the global search. Empty query clears results.
    private func scheduleGlobalSearch(_ raw: String) {
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            messageResults = []
            searchingMessages = false
            return
        }
        searchingMessages = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if let response = try? await APIClient.shared.searchMessages(query: query), !Task.isCancelled {
                messageResults = response.results
            } else if !Task.isCancelled {
                messageResults = []
            }
            searchingMessages = false
        }
    }

    /// Strip the `<b>…</b>` match markers the server wraps around hits (rendered plain).
    static func plainSnippet(_ snippet: String?) -> String {
        guard let snippet else { return "" }
        return snippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }

    static func stamp(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let df2 = ISO8601DateFormatter(); df2.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: iso) ?? df2.date(from: iso) else { return nil }
        let f = DateFormatter()
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MM/dd/yy"
        }
        return f.string(from: date)
    }

    // MARK: §16.5 row actions

    /// Mark as Read without opening the chat: the same message:read signal the chat
    /// view emits, plus an immediate local badge clear.
    private func markAsRead(_ convo: Conversation) {
        SocketService.shared.emit("message:read", ["conversationId": convo.id])
        store.clearUnread(conversationId: convo.id)
    }

    /// Mute/unmute messages via the existing prefs plumbing (§8.2): optimistic local
    /// mirror first so foreground gating updates instantly, then the PUT.
    private func applyMute(_ conversationId: String, optionId: String) {
        let value = ChatNotificationsCard.muteValue(for: optionId)
        var prefs = ChatLocalPrefs.cachedMutes(conversationId)
        prefs.messagesMutedUntil = value
        ChatLocalPrefs.cacheMutes(conversationId, prefs: prefs)
        Task {
            if let updated = try? await APIClient.shared.updateConversationPrefs(
                conversationId: conversationId, messagesMutedUntil: .some(value)) {
                ChatLocalPrefs.cacheMutes(conversationId, prefs: updated)
            }
        }
    }

    private func deleteConversation(_ convo: Conversation) async {
        do {
            _ = try await APIClient.shared.deleteConversation(conversationId: convo.id)
            store.remove(conversationId: convo.id)
        } catch let e as APIError {
            actionError = e.userMessage
        } catch {
            actionError = String(localized: "Couldn't delete this chat right now.")
        }
    }
}

/// §18.4: a navigation route that opens a conversation AND jumps to a specific message
/// (from a global-search hit).
struct MessageJump: Hashable {
    let conversation: Conversation
    let messageId: String
}

// MARK: - §16.5 long-press menu overlay

/// Dimmed full-screen menu for a chat row — mirrors the message long-press overlay's
/// visual language: a compact preview of the row on top, the action list below.
private struct ConversationActionsOverlay: View {
    let conversation: Conversation
    let isMuted: Bool
    let onMarkRead: () -> Void
    let onTogglePin: () -> Void
    let onMute: () -> Void
    let onUnmute: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private var unread: Int { conversation.unreadCount ?? 0 }
    private var title: String { conversationTitle(conversation) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 12) {
                previewCard
                actionsCard
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 420)
        }
    }

    private var previewCard: some View {
        HStack(spacing: 12) {
            AvatarView(
                url: conversation.type == "GROUP" ? conversation.avatarUrl : conversation.members.first?.avatarUrl,
                name: title,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(KlicFont.headline(15))
                    .foregroundStyle(KlicColor.textPrimary)
                    .lineLimit(1)
                Text(lastMessageText(conversation.lastMessage))
                    .font(KlicFont.body(13))
                    .foregroundStyle(KlicColor.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 300, alignment: .leading)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            if unread > 0 {
                row(title: String(localized: "Mark as Read"), systemImage: "envelope.open") { onMarkRead() }
                Divider().overlay(KlicColor.surfaceRaised)
            }
            row(
                title: conversation.isChatPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                systemImage: conversation.isChatPinned ? "pin.slash" : "pin"
            ) { onTogglePin() }
            Divider().overlay(KlicColor.surfaceRaised)
            row(
                title: isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                systemImage: isMuted ? "bell" : "bell.slash"
            ) { isMuted ? onUnmute() : onMute() }
            Divider().overlay(KlicColor.surfaceRaised)
            row(title: String(localized: "Delete"), systemImage: "trash", destructive: true) { onDelete() }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 260)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private func row(
        title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(KlicFont.body(15))
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 16))
            }
            .foregroundStyle(destructive ? KlicColor.danger : KlicColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    @ObservedObject private var socket = SocketService.shared

    var title: String { conversationTitle(conversation) }
    private var isOnline: Bool {
        guard conversation.type == "DIRECT" else { return false }
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    private var unread: Int { conversation.unreadCount ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(
                    url: conversation.type == "GROUP" ? conversation.avatarUrl : conversation.members.first?.avatarUrl,
                    name: title,
                    size: 52
                )
                    .overlay(alignment: .bottomTrailing) {
                        if isOnline {
                            Circle().fill(.green).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(KlicColor.background, lineWidth: 2))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
                    if conversation.type == "GROUP" {
                        Text(groupMemberSummary(conversation))
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                            .lineLimit(1)
                    }
                    Text(lastMessageText(conversation.lastMessage))
                        .font(KlicFont.body(14)).foregroundStyle(KlicColor.textMuted)
                        .lineLimit(2)
                }
                Spacer()
                // Date pinned top-right (with my read-status tick to its left); unread
                // badge (and the §16.5 pin indicator) beneath.
                VStack(alignment: .trailing, spacing: 6) {
                    if let stamp = lastMessageStamp(conversation.lastMessage) {
                        HStack(spacing: 3) {
                            if let status = conversation.lastMessage?.status {
                                // §11.6: read receipts OFF hides blue ticks in DMs.
                                let hideRead = status == "read" && conversation.type == "DIRECT" && !PrivacyPrefs.readReceipts
                                MessageTicks(status: hideRead ? "delivered" : status)
                            }
                            Text(stamp).font(KlicFont.caption(12)).foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    HStack(spacing: 6) {
                        if conversation.isChatPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(KlicFont.caption(12).weight(.semibold))
                                .foregroundStyle(KlicColor.onPrimary)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(KlicColor.primary, in: Capsule())
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.vertical, 12)
            // Divider inset to start under the text content, not under the avatar.
            Rectangle()
                .fill(KlicColor.textPrimary.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 66)
        }
    }
}

private func conversationTitle(_ conversation: Conversation) -> String {
    if conversation.type == "GROUP" {
        if let title = conversation.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        let members = conversation.members.map(\.displayName).joined(separator: ", ")
        return members.isEmpty ? "Group" : members
    }
    return conversation.members.first?.displayName ?? "Direct"
}

private func groupMemberSummary(_ conversation: Conversation) -> String {
    let members = conversation.members.map(\.displayName).joined(separator: ", ")
    return members.isEmpty ? "No members yet" : members
}

/// Last-message stamp for the chat list: clock time today (e.g. "3:26 PM"), "MM/dd" earlier
/// this year, "MM/dd/yy" before that — or nil if unknown.
private func lastMessageStamp(_ m: Message?) -> String? {
    guard let iso = m?.createdAt, !iso.isEmpty else { return nil }
    let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let df2 = ISO8601DateFormatter(); df2.formatOptions = [.withInternetDateTime]
    guard let date = df.date(from: iso) ?? df2.date(from: iso) else { return nil }
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(date) {
        f.dateFormat = "h:mm a"
    } else if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
        f.dateFormat = "MM/dd"
    } else {
        f.dateFormat = "MM/dd/yy"
    }
    return f.string(from: date)
}

/// One-line summary of the last message for the chat list (no emoji, per the design system).
private func lastMessageText(_ m: Message?) -> String {
    guard let m else { return "Say hi" }
    if m.isDeleted { return "Message deleted" }
    if m.isCallEvent { return m.call?.isVideo == true ? "Video call" : "Voice call" }
    if m.isSticker { return "Sticker" }
    if !m.body.isEmpty { return m.body }
    switch m.attachments.first?.kind {
    case "IMAGE":      return "Photo"
    case "VIDEO":      return "Video"
    case "VOICE":      return "Voice message"
    case "VIDEO_NOTE": return "Video message"
    case .some:        return "File"
    default:           return "Say hi"
    }
}
