import SwiftUI
import Inject

/// A friend's profile (§9.6): the same info sections as the user's own Profile page
/// (large avatar, display name, copyable @username chip, presence), Audio / Video /
/// Message actions, "Groups in common" from the cached conversations list, and — when
/// reached from a chat — the shared chat-info sections.
struct ProfileView: View {
    @ObserveInjection var inject
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    var onCall: (String) -> Void          // "AUDIO" | "VIDEO"
    var onMessage: (() -> Void)? = nil    // shown only when provided (e.g. from Friends)
    var onInvite: (() -> Void)? = nil
    /// When opened from a chat: the direct conversation's id — unlocks the chat-info
    /// sections (media browser, starred, storage, save-to-photos, notifications; §8.4).
    var conversationId: String? = nil
    /// Chat members (incl. the current user) for sender-name resolution in those sections.
    var chatMembers: [ChatProfileTarget] = []

    @ObservedObject private var socket = SocketService.shared
    @ObservedObject private var store = ConversationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var openedGroup: Conversation?
    /// §10.2: when opened from the Friends list (no conversationId), the DM is
    /// resolved via POST /conversations {userId} so both entry points show the SAME
    /// full sections.
    @State private var resolvedConversationId: String?
    // Block flow (§10.4, §16.6 confirm polish): confirm sheet → POST /blocks,
    // optionally followed by the existing delete-conversation flow.
    @State private var showBlockConfirm = false
    @State private var blocking = false
    @State private var blockError: String?
    // Remove Friend (§16.6): confirm → DELETE /friends/:userId.
    @State private var showRemoveFriendConfirm = false
    @State private var removingFriend = false
    @State private var removeFriendError: String?
    // Report flow (§12.1).
    @State private var reportTarget: ReportTarget?
    // §14.3: friendship state — drives the "Add friend" button on non-friend profiles.
    @State private var friendshipKnown = false
    @State private var isFriend = false
    @State private var friendRequestSent = false
    @State private var sendingFriendRequest = false
    @State private var friendError: String?

    private var effectiveConversationId: String? { conversationId ?? resolvedConversationId }

    private var showsAddFriend: Bool {
        friendshipKnown && !isFriend && userId != AccessToken.subject(of: TokenStore.accessToken)
    }

    private var resolvedAvatar: String? { profile?.avatarUrl ?? avatarUrl }

    /// GROUP conversations from the cached list that include this friend (§9.6).
    private var groupsInCommon: [Conversation] {
        store.conversations.filter { convo in
            convo.type == "GROUP" && convo.members.contains(where: { $0.id == userId })
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Info header — mirrors the user's own Profile page styling.
                AvatarView(url: resolvedAvatar, name: displayName, size: 120)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text(displayName)
                        .font(KlicFont.headline(24))
                        .foregroundStyle(KlicColor.textPrimary)
                    CopyableUsername(username: username)
                    // §11.5: the friend's About line, when they share it with us.
                    if let aboutText = profile?.about?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !aboutText.isEmpty {
                        Text(aboutText)
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    if let presence = presenceText {
                        Text(presence)
                            .font(KlicFont.caption())
                            .foregroundStyle(isOnline ? KlicColor.primary : KlicColor.textMuted)
                    }
                }

                HStack(spacing: 16) {
                    CallActionButton(systemName: "phone.fill", label: String(localized: "Audio")) { onCall("AUDIO"); dismiss() }
                    CallActionButton(systemName: "video.fill", label: String(localized: "Video")) { onCall("VIDEO"); dismiss() }
                    if let onMessage {
                        CallActionButton(systemName: "message.fill", label: String(localized: "Message")) { onMessage(); dismiss() }
                    }
                    if let onInvite {
                        CallActionButton(systemName: "person.badge.plus.fill", label: String(localized: "Invite")) { onInvite(); dismiss() }
                    }
                }
                .padding(.top, 8)

                // Chat-info sections — both entry points (chat header AND friends
                // list) land on the same full component (§10.2). From the friends
                // list the DM id is resolved lazily in .task.
                // §14.3: "Add friend" for non-friend profiles (group members with no
                // shared context) — sends the normal request.
                if showsAddFriend {
                    PillButton(
                        title: friendRequestSent
                            ? String(localized: "Friend request sent")
                            : String(localized: "Add friend"),
                        fill: friendRequestSent ? KlicColor.surfaceRaised : KlicColor.primary,
                        textColor: friendRequestSent ? KlicColor.textMuted : KlicColor.onPrimary
                    ) {
                        Task { await addFriend() }
                    }
                    .disabled(friendRequestSent || sendingFriendRequest)
                    .padding(.top, 4)
                    if let friendError {
                        Text(friendError)
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.danger)
                            .multilineTextAlignment(.center)
                    }
                }

                if let chatId = effectiveConversationId {
                    ChatInfoCommonRows(
                        conversationId: chatId,
                        members: chatMembers.isEmpty
                            ? [ChatProfileTarget(id: userId, username: username, displayName: displayName, avatarUrl: avatarUrl)]
                            : chatMembers
                    )
                    .padding(.top, 12)

                    // §14.3: per-DM local chat theme + encryption info.
                    ChatThemeEncryptionRows(conversationId: chatId, isGroup: false)

                    ChatNotificationsCard(conversationId: chatId, isGroup: false)
                }

                // §11.5: the friend's shared links (subject to their visibility).
                if let shared = profile?.links, !shared.isEmpty {
                    linksCard(shared)
                }

                if !groupsInCommon.isEmpty {
                    groupsInCommonCard
                }

                // Remove Friend (§16.6) — with confirm; the chat stays in the list.
                if friendshipKnown, isFriend {
                    PillButton(
                        title: removingFriend ? String(localized: "Removing…") : String(localized: "Remove Friend"),
                        fill: KlicColor.surface,
                        textColor: KlicColor.danger
                    ) {
                        showRemoveFriendConfirm = true
                    }
                    .disabled(removingFriend)
                    .padding(.top, 8)
                }

                // Block (§10.4) — with confirm; blocked users are managed in
                // Settings → Privacy and Security → Blocked Users.
                PillButton(
                    title: blocking ? String(localized: "Blocking…") : String(localized: "Block User"),
                    fill: KlicColor.surface,
                    textColor: KlicColor.danger
                ) {
                    showBlockConfirm = true
                }
                .disabled(blocking)
                .padding(.top, 8)

                // Report (§12.1): category → details → submit, with a block shortcut.
                PillButton(
                    title: String(localized: "Report User"),
                    fill: KlicColor.surface,
                    textColor: KlicColor.danger
                ) {
                    reportTarget = .user(id: userId, username: username, displayName: displayName)
                }

                if let inlineError = removeFriendError ?? blockError {
                    Text(inlineError)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedGroup) { group in
            ChatView(conversation: group)
        }
        .task {
            // §9.9: cached profile paints instantly; the fetch reconciles.
            if profile == nil { profile = ChatCaches.profiles[userId] }
            if let fetched = try? await APIClient.shared.userProfile(id: userId) {
                profile = fetched
                ChatCaches.profiles[userId] = fetched
            }
            // Groups in common come from the conversations cache — warm it if needed.
            if store.conversations.isEmpty { await store.refresh() }
            // §14.3: resolve friendship for the "Add friend" affordance.
            if !friendshipKnown {
                let friends = ChatCaches.friends.isEmpty
                    ? ((try? await APIClient.shared.friends()) ?? [])
                    : ChatCaches.friends
                if !friends.isEmpty { ChatCaches.friends = friends }
                isFriend = friends.contains { $0.id == userId }
                friendshipKnown = true
            }
            // §10.2: no conversation context → resolve the DM (POST returns the
            // existing conversation) so the full sections render here too.
            if conversationId == nil, resolvedConversationId == nil {
                resolvedConversationId = (try? await APIClient.shared.openConversation(userId: userId))?.id
            }
        }
        // §16.6: block confirm explains the effect and offers "Also delete the chat"
        // inline (off by default) — the delete runs after a successful block.
        .sheet(isPresented: $showBlockConfirm) {
            BlockConfirmSheet(displayName: displayName) { alsoDeleteChat in
                Task { await blockUser(alsoDeleteChat: alsoDeleteChat) }
            }
        }
        // §16.6: Remove Friend confirm — the chat and its history stay.
        .klicSelectionSheet(
            isPresented: $showRemoveFriendConfirm,
            title: String(localized: "Remove \(displayName) from your friends?"),
            message: String(localized: "The chat and its history stay in your list."),
            options: [KlicSheetOption(id: "remove", label: String(localized: "Remove Friend"), isDestructive: true)]
        ) { _ in
            Task { await removeFriend() }
        }
        .reportSheet(target: $reportTarget)
        .enableInjection()
    }

    // MARK: Links (§11.5)

    private func linksCard(_ shared: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Links")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(Array(shared.enumerated()), id: \.offset) { index, link in
                Button {
                    if let url = URL(string: link) { LinkOpener.open(url) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(KlicColor.primary)
                        Text(link)
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < shared.count - 1 {
                    Divider().padding(.leading, 44).opacity(0.4)
                }
            }
            Color.clear.frame(height: 8)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Groups in common (§9.6)

    private var groupsInCommonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(groupsInCommon.count == 1 ? String(localized: "1 group in common") : String(localized: "\(groupsInCommon.count) groups in common"))
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)

            ForEach(Array(groupsInCommon.enumerated()), id: \.element.id) { index, group in
                Button {
                    openedGroup = group
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: group.avatarUrl, name: groupTitle(group), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(groupTitle(group))
                                .font(KlicFont.medium())
                                .foregroundStyle(KlicColor.textPrimary)
                                .lineLimit(1)
                            Text(memberCountText(group))
                                .font(KlicFont.caption())
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < groupsInCommon.count - 1 {
                    Divider().padding(.leading, 74).opacity(0.4)
                }
            }
            Color.clear.frame(height: 8)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func groupTitle(_ group: Conversation) -> String {
        if let title = group.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title
        }
        let members = group.members.map(\.displayName).joined(separator: ", ")
        return members.isEmpty ? "Group" : members
    }

    private func memberCountText(_ group: Conversation) -> String {
        // The list payload's members exclude the current user — count them back in.
        let count = group.members.count + 1
        return count == 1 ? String(localized: "1 member") : String(localized: "\(count) members")
    }

    // MARK: Add friend (§14.3)

    private func addFriend() async {
        sendingFriendRequest = true
        defer { sendingFriendRequest = false }
        friendError = nil
        do {
            _ = try await APIClient.shared.sendFriendRequest(userId: userId)
            friendRequestSent = true
        } catch let e as APIError {
            friendError = e.userMessage
        } catch {
            friendError = String(localized: "Couldn't send the friend request right now.")
        }
    }

    // MARK: Remove Friend (§16.6)

    private func removeFriend() async {
        removingFriend = true
        defer { removingFriend = false }
        removeFriendError = nil
        do {
            try await APIClient.shared.removeFriend(userId: userId)
            ChatCaches.friends.removeAll { $0.id == userId }
            // The profile flips to the non-friend "Add friend" state; the chat stays.
            isFriend = false
            friendRequestSent = false
        } catch let e as APIError {
            removeFriendError = e.userMessage
        } catch {
            removeFriendError = String(localized: "Couldn't remove this friend right now.")
        }
    }

    // MARK: Block (§10.4, §16.6)

    private func blockUser(alsoDeleteChat: Bool) async {
        blocking = true
        defer { blocking = false }
        do {
            try await BlockStore.shared.block(userId: userId)
            ChatCaches.friends.removeAll { $0.id == userId }
            isFriend = false
            if alsoDeleteChat, let chatId = effectiveConversationId {
                // The existing delete-conversation flow, after the block succeeded.
                // Best-effort: a failure leaves the (now blocked) chat in the list.
                if (try? await APIClient.shared.deleteConversation(conversationId: chatId)) != nil {
                    ConversationStore.shared.remove(conversationId: chatId)
                }
            }
            dismiss()
        } catch let e as APIError {
            blockError = e.userMessage
        } catch {
            blockError = String(localized: "Couldn't block this user right now.")
        }
    }

    // MARK: Presence

    private var isOnline: Bool { socket.presence[userId]?.online == true }

    private var presenceText: String? {
        if isOnline { return String(localized: "Online") }
        let live = socket.presence[userId]?.lastSeen
        let fetched = profile?.lastSeenAt.flatMap(SocketService.parseDate)
        guard let date = live ?? fetched else { return nil }
        return Self.lastSeen(date)
    }

    private static func lastSeen(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return String(localized: "last seen today at \(f.string(from: date))") }
        if cal.isDateInYesterday(date) { f.dateFormat = "HH:mm"; return String(localized: "last seen yesterday at \(f.string(from: date))") }
        f.dateFormat = "MMM d"; return String(localized: "last seen \(f.string(from: date))")
    }
}

/// §16.6 block confirm: explains the effect, offers "Also delete the chat" inline
/// (off by default), destructive Block action + Cancel — styled like the shared
/// Klic bottom sheet (§9.2).
private struct BlockConfirmSheet: View {
    let displayName: String
    let onBlock: (_ alsoDeleteChat: Bool) -> Void

    @State private var alsoDeleteChat = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Block \(displayName)?")
                    .font(KlicFont.headline(16))
                    .foregroundStyle(KlicColor.textPrimary)
                Text("They won't be able to message or call you. You can unblock them from Settings → Privacy and Security.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle(isOn: $alsoDeleteChat) {
                        Text("Also delete the chat")
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.textPrimary)
                    }
                    .tint(KlicColor.primary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().padding(.leading, 20).opacity(0.4)

                Button {
                    let deleteChat = alsoDeleteChat
                    dismiss()
                    onBlock(deleteChat)
                } label: {
                    HStack {
                        Text("Block User")
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.danger)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)

            PillButton(title: String(localized: "Cancel"), fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationBackground(KlicColor.background)
    }
}

private struct CallActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 60, height: 60)
                    .background(KlicColor.primary, in: Circle())
                Text(label)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }
}
