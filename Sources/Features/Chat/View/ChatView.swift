import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import Inject

struct ChatView: View {
    @ObserveInjection var inject
    let conversation: Conversation
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var socket = SocketService.shared

    @State var messages: [Message] = []
    @State var hasMore = false
    @State var isLoadingMore = false
    @State var initialLoadDone = false
    @State var draft = ""
    @State var scrollProxy: ScrollViewProxy?
    @State var atBottom = true

    @StateObject var recorder = AudioRecorder()
    @FocusState var isComposerFocused: Bool
    @State var pickedItems: [PhotosPickerItem] = []
    @State var showAttachMenu = false
    @State var showPhotos = false
    @State var showCamera = false
    @State var showFileImporter = false
    @State var showStickers = false
    @State var uploading = false

    // Reply / long-press menu / local-delete state.
    @State var replyingTo: Message?
    @State var menuTarget: Message?
    @State private var deleteTarget: Message?
    /// §12.1: message being reported via the long-press menu.
    @State private var reportTarget: ReportTarget?
    @State var hiddenIds: Set<String> = []
    @State var lastTypingSent = Date.distantPast
    @State var isStartingCall = false
    @State var selectedMember: ChatProfileTarget?
    @State var openedConversation: Conversation?
    @State var groupDetails: GroupConversationDetails?
    /// The conversation's in-progress call (group chats) — drives the "Join call" banner.
    @State var activeCallInfo: ActiveCallInfo?
    @ObservedObject var callKit = CallKitManager.shared
    @State var pendingMedia: [PendingMediaDraft] = []
    /// The staged item currently open in the pre-send media editor (§10.9).
    @State var editingDraft: PendingMediaDraft?
    /// Optimistic in-flight sends rendered as progress pills at the list's tail (§9.1).
    /// §14.2: owned by the session-scoped UploadCenter so pills survive leaving and
    /// re-entering the chat mid-upload.
    @ObservedObject var uploadCenter = UploadCenter.shared
    @State var selectedMediaAttachmentId: String?
    @State var captureMode: MessageComposer.CaptureMode = .audio
    @State var cameraMode: CameraPicker.Mode = .photo
    // Message search (group info → Search; §8.4).
    @State var showMessageSearch = false
    @State var pendingSearchJump: String?

    enum AttachAction { case photos, camera, file, scan }
    @State var pendingAttach: AttachAction?
    /// VisionKit document camera (§10.11).
    @State var showDocScanner = false

    var isDirect: Bool { conversation.type == "DIRECT" }
    var title: String {
        if let groupTitle = groupDetails?.title?.trimmingCharacters(in: .whitespaces), !groupTitle.isEmpty {
            return groupTitle
        }
        if let groupTitle = conversation.title?.trimmingCharacters(in: .whitespaces), !groupTitle.isEmpty {
            return groupTitle
        }
        if isDirect { return conversation.members.first?.displayName ?? "Chat" }
        let members = memberTargets.map(\.displayName).joined(separator: ", ")
        return members.isEmpty ? "Group" : members
    }
    var myId: String? { session.currentUser?.id }
    var memberCount: Int { memberTargets.count }
    var memberTargets: [ChatProfileTarget] {
        if let groupDetails {
            return groupDetails.members.map {
                ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl)
            }
        }
        var ordered: [ChatProfileTarget] = conversation.members.map {
            ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl)
        }
        if let me = session.currentUser {
            ordered.append(ChatProfileTarget(id: me.id, username: me.username, displayName: me.displayName, avatarUrl: me.avatarUrl))
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }
    var groupAvatarUrl: String? { groupDetails?.avatarUrl ?? conversation.avatarUrl }

    /// Messages minus anything the user deleted just for themselves (local-only).
    var visibleMessages: [Message] { messages.filter { !hiddenIds.contains($0.id) } }
    /// This chat's in-flight upload pills, re-attached from the registry (§14.2).
    var outgoingUploads: [OutgoingUpload] { uploadCenter.uploads(in: conversation.id) }
    var mediaGalleryItems: [ChatMediaGalleryItem] {
        visibleMessages.flatMap { message in
            message.attachments.compactMap { attachment in
                guard attachment.isImage || attachment.isVideo else { return nil }
                return ChatMediaGalleryItem(
                    id: attachment.id,
                    attachmentId: attachment.id,
                    messageId: message.id,
                    url: attachment.url,
                    isVideo: attachment.isVideo,
                    caption: message.body,
                    senderName: senderDisplayName(for: message.senderId),
                    createdAt: message.createdAt,
                    reactions: message.reactions,
                    isMine: message.senderId == myId,
                    durationMs: attachment.durationMs,
                    thumbnailURL: attachment.isImage ? attachment.url : nil,
                    starred: message.starred == true,
                    attachment: attachment
                )
            }
        }
    }

    /// Whether the peer is currently typing in this conversation (auto-expires).
    var peerIsTyping: Bool {
        guard let at = socket.typingByConversation[conversation.id] else { return false }
        return Date().timeIntervalSince(at) < 6
    }

    var body: some View {
        messageList
            // The composer floats over the chat as a bottom inset: transparent background so
            // messages scroll behind it, and the inset reserves space so the newest message
            // is never hidden/clipped behind it (incl. when the keyboard opens).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !pendingMedia.isEmpty {
                        PendingMediaComposerBar(
                            items: pendingMedia,
                            onRemove: { id in
                                pendingMedia.removeAll { $0.id == id }
                            },
                            onEdit: { id in
                                editingDraft = pendingMedia.first { $0.id == id }
                            }
                        )
                    }
                    if let target = replyingTo {
                        ReplyComposerBar(
                            authorName: target.senderId == myId ? String(localized: "yourself") : title,
                            preview: previewText(for: target),
                            onCancel: { withAnimation { replyingTo = nil } }
                        )
                    }
                    // "@" typed in a group composer → member/@all suggestions (§9.5).
                    if !mentionSuggestions.isEmpty {
                        MentionSuggestionStrip(suggestions: mentionSuggestions) { insertMention($0) }
                    }
                    composer
                }
            }
            // "Join call" banner: the group has a live call we're not in yet.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let info = activeCallInfo, callKit.activeCall?.id != info.callId {
                    JoinCallBanner(info: info) {
                        Task { await joinActiveCall(info) }
                    }
                }
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // §12.3: background color → gradient → low-opacity pattern → messages.
        // §13.4: the background stack is anchored to the SCREEN, not the keyboard-
        // adjusted content area — a fixed screen-sized frame pinned to the top plus
        // keyboard-inset exemption, so opening the keyboard moves only the
        // messages/composer and never shifts the pattern.
        .background(alignment: .top) {
            ChatThemeBackground(conversationId: conversation.id)
                .frame(
                    width: UIScreen.main.bounds.width,
                    height: UIScreen.main.bounds.height
                )
                .ignoresSafeArea(.container, edges: .all)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { chatHeader }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 20) {
                    Button { Task { await startCall(kind: "AUDIO") } } label: {
                        Image(systemName: "phone.fill").font(.system(size: 18))
                    }
                    .disabled(isStartingCall)
                    Button { Task { await startCall(kind: "VIDEO") } } label: {
                        Image(systemName: "video.fill").font(.system(size: 18))
                    }
                    .disabled(isStartingCall)
                }
            }
        }
        .overlay {
            if let target = menuTarget {
                MessageActionsOverlay(
                    message: target,
                    isMine: target.senderId == myId,
                    peerName: title,
                    onReact: { emoji in
                        Task { await react(target, emoji: emoji) }
                        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
                    },
                    onReply: { replyingTo = target; isComposerFocused = true },
                    onCopy: { UIPasteboard.general.string = target.body },
                    onToggleStar: { Task { await toggleStar(target) } },
                    onReport: {
                        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
                        let sender = memberTargets.first { $0.id == target.senderId }
                        reportTarget = .message(
                            id: target.id,
                            senderId: sender?.id ?? target.senderId,
                            senderUsername: sender?.username,
                            senderDisplayName: sender?.displayName
                        )
                    },
                    onDelete: { deleteTarget = target },
                    onDismiss: { withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil } }
                )
                .transition(.opacity)
            }
        }
        .reportSheet(target: $reportTarget)
        .sheet(isPresented: $showMessageSearch, onDismiss: {
            if let target = pendingSearchJump {
                pendingSearchJump = nil
                Task { await jumpToMessage(target) }
            }
        }) {
            MessageSearchSheet(
                messages: messages,
                hasMore: hasMore,
                isLoadingMore: isLoadingMore,
                senderName: { senderDisplayName(for: $0) },
                onLoadMore: { Task { await loadMore() } },
                onSelect: { pendingSearchJump = $0 }
            )
        }
        .klicSelectionSheet(
            isPresented: deleteDialogBinding,
            title: String(localized: "Delete message"),
            options: deleteOptions,
            onDismiss: { dismissMenu() }
        ) { option in
            guard let m = deleteTarget else { return }
            if option.id == "me" { deleteForMe(m) }
            else { Task { await deleteEveryone(m) } }
            dismissMenu()
        }
        .task {
            hiddenIds = Self.loadHidden(conversation.id)
            // Restore this chat's saved composer draft (§10.4).
            if draft.isEmpty {
                draft = ChatDrafts.load(conversation.id)
            }
            await load()
            if !isDirect {
                await loadGroupDetails()
                await refreshActiveCall()
            }
            scrollToBottom(animated: false)
            initialLoadDone = true
        }
        .onAppear { isComposerFocused = true }
        .onDisappear {
            emitTyping(false)
            // Persist unsent text as this chat's draft (§10.4).
            ChatDrafts.save(conversation.id, text: draft)
        }
        .onChange(of: draft) { _, value in emitTyping(!value.trimmingCharacters(in: .whitespaces).isEmpty) }
        // Keep the cached first page fresh so re-opening this chat paints instantly (§9.9).
        .onChange(of: messages) { _, value in
            guard !value.isEmpty else { return }
            ChatCaches.messagePages[conversation.id] = Array(value.suffix(50))
        }
        // Re-verify call state when the app comes back to the foreground (§9.7).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isDirect else { return }
            Task { await refreshActiveCall() }
        }
        .onReceive(socket.$lastMessage.compactMap { $0 }) { msg in
            guard msg.conversationId == conversation.id else { return }
            // Upsert by id — the server echoes our own sends back for multi-device sync.
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                var updated = msg
                // Socket fan-out is per-conversation, not per-requester — keep my star.
                updated.starred = updated.starred ?? messages[idx].starred
                messages[idx] = updated
            } else {
                messages.append(msg)
            }
            // SYSTEM fanout (members added/removed) — refresh the member list.
            if !isDirect, msg.isSystem {
                Task { await loadGroupDetails() }
            }
            markRead()
            scrollToBottom()
        }
        // This user was removed from the group: drop it locally and close the chat (§9.3).
        .onReceive(socket.$lastConversationRemoved.compactMap { $0 }) { removedId in
            guard removedId == conversation.id else { return }
            dismiss()
        }
        // Group edits (title/cover/theme/admin) re-render live (§14.3).
        .onReceive(socket.$lastConversationUpdated.compactMap { $0 }) { updated in
            guard updated.id == conversation.id else { return }
            groupDetails = updated
        }
        // A background upload resolved into its server message (§14.2) — swap the
        // pill for the real bubble in place.
        .onReceive(uploadCenter.completions) { msg in
            guard msg.conversationId == conversation.id else { return }
            upsert(msg)
            if atBottom { scrollToBottom(animated: false) }
        }
        .onReceive(socket.$lastRead.compactMap { $0 }) { applyReceipt($0, status: "read") }
        .onReceive(socket.$lastDelivered.compactMap { $0 }) { applyReceipt($0, status: "delivered") }
        // Keep the "Join call" banner current as the call starts, gains members, or ends.
        .onReceive(socket.$incomingCall.compactMap { $0 }) { invite in
            guard invite.conversationId == conversation.id else { return }
            Task { await refreshActiveCall() }
        }
        .onReceive(socket.$lastCallParticipantJoined.compactMap { $0 }) { event in
            guard activeCallInfo?.callId == event.callId else { return }
            Task { await refreshActiveCall() }
        }
        .onReceive(socket.$lastCallParticipantLeft.compactMap { $0 }) { event in
            guard activeCallInfo?.callId == event.callId else { return }
            Task { await refreshActiveCall() }
        }
        .onReceive(socket.$lastCallEnded.compactMap { $0 }) { event in
            // Clear the banner the moment ITS call ends; any other call:end still
            // re-verifies, so a stale banner never survives a missed event (§9.7).
            if activeCallInfo?.callId == event.callId {
                activeCallInfo = nil
            } else if activeCallInfo != nil {
                Task { await refreshActiveCall() }
            }
        }
        .onReceive(socket.$lastReaction.compactMap { $0 }) { update in
            guard update.conversationId == conversation.id,
                  let idx = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            messages[idx].reactions = update.reactions
        }
        .onReceive(socket.$lastDeleted.compactMap { $0 }) { update in
            guard update.conversationId == conversation.id,
                  let idx = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            messages[idx].deletedAt = ISO8601DateFormatter().string(from: Date())
            messages[idx].reactions = []
        }
        .navigationDestination(item: $openedConversation) { opened in
            ChatView(conversation: opened)
        }
        .navigationDestination(item: $selectedMember) { member in
            ProfileView(
                userId: member.id,
                username: member.username,
                displayName: member.displayName,
                avatarUrl: member.avatarUrl,
                onCall: { kind in Task { await startDirectCall(with: member, kind: kind) } },
                onMessage: { Task { await openDirectChat(with: member) } },
                onInvite: { Task { await sendInvite(to: member) } }
            )
        }
        // Pre-send media editor (§10.9).
        .fullScreenCover(item: $editingDraft) { target in
            MediaEditorView(draft: target, caption: $draft) { updated in
                if let idx = pendingMedia.firstIndex(where: { $0.id == target.id }) {
                    pendingMedia[idx] = updated
                }
            }
        }
        .fullScreenCover(isPresented: mediaViewerPresented) {
            if let selectedMediaAttachmentId {
                MediaViewer(
                    items: mediaGalleryItems,
                    selectedAttachmentId: selectedMediaAttachmentId,
                    onClose: { self.selectedMediaAttachmentId = nil },
                    onReact: { messageId, emoji in
                        guard let message = messages.first(where: { $0.id == messageId }) else { return }
                        Task { await react(message, emoji: emoji) }
                    },
                    onDeleteForMe: { messageId in
                        guard let message = messages.first(where: { $0.id == messageId }) else { return }
                        deleteForMe(message)
                    },
                    onDeleteEveryone: { messageId in
                        guard let message = messages.first(where: { $0.id == messageId }) else { return }
                        Task { await deleteEveryone(message) }
                    },
                    onToggleStar: { messageId in
                        guard let message = messages.first(where: { $0.id == messageId }) else { return }
                        Task { await toggleStar(message) }
                    },
                    onReply: { messageId in
                        guard let message = messages.first(where: { $0.id == messageId }) else { return }
                        replyingTo = message
                        isComposerFocused = true
                    }
                )
            }
        }
        .enableInjection()
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var deleteOptions: [KlicSheetOption] {
        var options = [KlicSheetOption(id: "me", label: String(localized: "Delete for me"), isDestructive: true)]
        if deleteTarget?.senderId == myId {
            options.append(KlicSheetOption(id: "everyone", label: String(localized: "Delete for everyone"), isDestructive: true))
        }
        return options
    }

    var mediaViewerPresented: Binding<Bool> {
        Binding(
            get: { selectedMediaAttachmentId != nil },
            set: { if !$0 { selectedMediaAttachmentId = nil } }
        )
    }

    private func dismissMenu() {
        deleteTarget = nil
        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
    }
}

struct ChatProfileTarget: Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    let avatarUrl: String?
}

/// Banner shown at the top of a group chat while the group has a call in progress
/// that this user hasn't joined yet.
private struct JoinCallBanner: View {
    let info: ActiveCallInfo
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info.kind == "VIDEO" ? "video.fill" : "phone.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KlicColor.onPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ongoing call")
                    .font(KlicFont.headline(14))
                    .foregroundStyle(KlicColor.onPrimary)
                Text(info.joinedCount == 1 ? String(localized: "1 person in the call") : String(localized: "\(info.joinedCount) people in the call"))
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.onPrimary.opacity(0.85))
            }
            Spacer()
            Button(action: onJoin) {
                Text("Join")
                    .font(KlicFont.headline(14))
                    .foregroundStyle(KlicColor.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(KlicColor.onPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KlicColor.primary)
    }
}
