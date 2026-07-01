import SwiftUI

/// Calls, sender lookups, and cross-navigation to profiles/direct chats.
extension ChatView {
    func startCall(kind: String) async {
        guard isDirect else { return }
        guard !isStartingCall else { return }
        isStartingCall = true
        defer { isStartingCall = false }
        guard let s = try? await APIClient.shared.startCall(conversationId: conversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            s,
            peerName: title,
            peerId: conversation.members.first?.id,
            peerAvatarUrl: conversation.members.first?.avatarUrl
        )
    }

    func senderDisplayName(for userId: String) -> String {
        if userId == myId {
            return session.currentUser?.displayName ?? "You"
        }
        return memberTargets.first(where: { $0.id == userId })?.displayName ?? "User"
    }

    func senderAvatarURL(for userId: String) -> String? {
        if userId == myId {
            return session.currentUser?.avatarUrl
        }
        return memberTargets.first(where: { $0.id == userId })?.avatarUrl
    }

    func replyAuthorName(for userId: String) -> String {
        userId == myId ? "You" : senderDisplayName(for: userId)
    }

    func openProfile(for userId: String) {
        guard userId != myId else { return }
        guard let member = memberTargets.first(where: { $0.id == userId }) else { return }
        selectedMember = member
    }

    func openDirectChat(with member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        if let conversation = try? await APIClient.shared.openConversation(userId: member.id) {
            await MainActor.run {
                self.selectedMember = nil
                self.openedConversation = conversation
            }
        }
    }

    func startDirectCall(with member: ChatProfileTarget, kind: String) async {
        guard member.id != myId else { return }
        guard let directConversation = try? await APIClient.shared.openConversation(userId: member.id),
              let session = try? await APIClient.shared.startCall(conversationId: directConversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            session,
            peerName: member.displayName,
            peerId: member.id,
            peerAvatarUrl: member.avatarUrl
        )
    }

    func sendInvite(to member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        _ = try? await APIClient.shared.sendFriendRequest(userId: member.id)
    }

    func loadGroupDetails() async {
        groupDetails = try? await APIClient.shared.conversationDetails(id: conversation.id)
    }
}
