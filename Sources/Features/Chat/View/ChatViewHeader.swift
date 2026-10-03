import SwiftUI

/// Tappable nav-bar title → the peer's or group's profile, with live presence/member count underneath.
extension ChatView {
    @ViewBuilder var chatHeader: some View {
        if isDirect, let peer = conversation.members.first {
            NavigationLink {
                ProfileView(
                    userId: peer.id, username: peer.username,
                    displayName: peer.displayName, avatarUrl: peer.avatarUrl,
                    onCall: { kind in Task { await startCall(kind: kind) } },
                    conversationId: conversation.id,
                    chatMembers: memberTargets
                )
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: peer.avatarUrl, name: peer.displayName, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(peer.displayName)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        // Small observing child: presence events re-render only this line,
                        // not ChatView's body.
                        ChatPresenceSubtitle(peerId: peer.id)
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                // Fixed theme surface (§10.8) — the pill must never adapt to the
                // content scrolling behind it, in light or dark.
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                GroupInfoView(
                    conversationId: conversation.id,
                    title: title,
                    initialDetails: groupDetails,
                    fallbackMembers: memberTargets,
                    onSelectMember: { member in
                        selectedMember = member
                    },
                    onUpdated: { details in
                        groupDetails = details
                    },
                    onDeleted: {
                        dismiss()
                    },
                    onStartCall: { kind in
                        Task { await startCall(kind: kind) }
                    },
                    onSearchMessages: {
                        showMessageSearch = true
                    }
                )
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: groupAvatarUrl, name: title, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        if let sub = headerSubtitle {
                            Text(sub)
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                // Fixed theme surface (§10.8) — never adapts to scrolled content.
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Group subtitle ("N members"); direct chats use `ChatPresenceSubtitle`.
    var headerSubtitle: String? {
        guard !isDirect else { return nil }
        return String(localized: "\(memberCount) members")
    }
}

/// Live presence line under a DM's title ("Online" / "last seen …"). Observes
/// SocketService itself so presence churn only re-evaluates this tiny view.
struct ChatPresenceSubtitle: View {
    let peerId: String
    @ObservedObject private var socket = SocketService.shared

    var body: some View {
        let info = socket.presence[peerId]
        if let sub = Self.subtitle(info) {
            Text(sub)
                .font(KlicFont.caption(11))
                .foregroundStyle(info?.online == true ? KlicColor.primary : KlicColor.textMuted)
        }
    }

    private static func subtitle(_ info: SocketService.PresenceInfo?) -> String? {
        if info?.online == true { return String(localized: "Online") }
        guard let date = info?.lastSeen else { return nil }
        let cal = Calendar.current
        // Locale-aware clock time (honors the 12/24-hour setting) instead of a fixed "HH:mm".
        if cal.isDateInToday(date) { return String(localized: "last seen \(KlicDate.shortTime.string(from: date))") }
        if cal.isDateInYesterday(date) { return String(localized: "last seen yesterday") }
        return String(localized: "last seen \(KlicDate.monthAbbrevDay.string(from: date))")
    }
}
