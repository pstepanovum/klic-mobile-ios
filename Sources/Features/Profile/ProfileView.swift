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
    // Block flow (§10.4): confirm sheet → POST /blocks.
    @State private var showBlockConfirm = false
    @State private var blocking = false
    @State private var blockError: String?

    private var effectiveConversationId: String? { conversationId ?? resolvedConversationId }

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
                if let chatId = effectiveConversationId {
                    ChatInfoCommonRows(
                        conversationId: chatId,
                        members: chatMembers.isEmpty
                            ? [ChatProfileTarget(id: userId, username: username, displayName: displayName, avatarUrl: avatarUrl)]
                            : chatMembers
                    )
                    .padding(.top, 12)

                    ChatNotificationsCard(conversationId: chatId, isGroup: false)
                }

                if !groupsInCommon.isEmpty {
                    groupsInCommonCard
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

                if let blockError {
                    Text(blockError)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 520)
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
            // §10.2: no conversation context → resolve the DM (POST returns the
            // existing conversation) so the full sections render here too.
            if conversationId == nil, resolvedConversationId == nil {
                resolvedConversationId = (try? await APIClient.shared.openConversation(userId: userId))?.id
            }
        }
        .klicSelectionSheet(
            isPresented: $showBlockConfirm,
            title: String(localized: "Block \(displayName)?"),
            message: String(localized: "They won't be able to message or call you. You can unblock them from Settings → Privacy and Security."),
            options: [KlicSheetOption(id: "block", label: String(localized: "Block User"), isDestructive: true)]
        ) { _ in
            Task { await blockUser() }
        }
        .enableInjection()
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

    // MARK: Block (§10.4)

    private func blockUser() async {
        blocking = true
        defer { blocking = false }
        do {
            _ = try await APIClient.shared.blockUser(userId: userId)
            ChatCaches.friends.removeAll { $0.id == userId }
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
