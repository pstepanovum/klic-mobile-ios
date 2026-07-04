import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import Inject

struct ChatView: View {
    @ObserveInjection var inject
    let conversation: Conversation
    /// §18.4: when opened from global search, the message to scroll to + flash on first load.
    var initialJumpMessageId: String? = nil
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
    @State var cameraMode: CameraPicker.Mode = .photo
    /// §16.2: hold/lock/cancel recording state (audio + round video) and the
    /// round-video capture pipeline.
    @StateObject var recSession = RecordingSession()
    @StateObject var noteRecorder = VideoNoteRecorder()
    /// §16.4: message being edited + the composer draft stashed while editing.
    @State var editingMessage: Message?
    @State var draftBeforeEdit = ""
    @State var editShakeTrigger = 0
    /// §16.3: pinned messages (oldest→newest), the bar's cycle cursor, and the
    /// "hidden until a new pin arrives" latch.
    @State var pinnedMessages: [ReplyPreview] = []
    @State var pinnedCursor = 0
    @State var hiddenNewestPinId: String?
    @State private var pinDialogTarget: Message?
    @State private var unpinDialogId: String?
    /// §16.1/§16.3: brief tinted pulse on a jumped-to bubble.
    @State var highlightedMessageId: String?
    // Message search (group info → Search; §8.4).
    @State var showMessageSearch = false
    @State var pendingSearchJump: String?
    // §18.4: in-chat header search — server-backed next/prev match navigation.
    @State var showInChatSearch = false
    @State var inChatSearchQuery = ""
    @State var inChatMatches: [String] = []      // messageIds, newest-first (server order)
    @State var inChatMatchIndex = 0
    @State var inChatSearching = false
    @State var inChatSearchTask: Task<Void, Never>?
    /// §16.6: who I've blocked — a blocked DM peer swaps the composer for the
    /// "You blocked <name>" banner (+ Unblock) in place.
    @ObservedObject var blockStore = BlockStore.shared
    @State var unblocking = false
    /// §16.6: quiet "Couldn't send" surface for failed sends (e.g. the peer
    /// blocked me → 403) — auto-hides; the text returns to the composer.
    @State var sendFailedNotice = false

    enum AttachAction { case photos, camera, file, scan }
    @State var pendingAttach: AttachAction?
    /// VisionKit document camera (§10.11).
    @State var showDocScanner = false

    var isDirect: Bool { conversation.type == "DIRECT" }
    /// §16.6: the DM peer (the list payload's members exclude the current user).
    var directPeer: Conversation.Member? { isDirect ? conversation.members.first : nil }
    var peerBlockedByMe: Bool {
        guard let peer = directPeer else { return false }
        return blockStore.blockedIds.contains(peer.id)
    }
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
                    // §16.6: a quiet, transient "Couldn't send" notice over the composer.
                    if sendFailedNotice {
                        Text("Couldn't send")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.danger)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(KlicColor.surface, in: Capsule())
                            .padding(.bottom, 6)
                            .transition(.opacity)
                    }
                    if peerBlockedByMe {
                        // §16.6: the composer is replaced while the DM peer is blocked
                        // by me; Unblock restores it in place.
                        BlockedComposerBanner(
                            name: directPeer?.displayName ?? title,
                            unblocking: unblocking,
                            onUnblock: { Task { await unblockPeer() } }
                        )
                    } else {
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
                        // §15.1: the reply preview lives INSIDE the composer's input
                        // container now — see MessageComposer.replyPreview.
                        // "@" typed in a group composer → member/@all suggestions (§9.5).
                        if !mentionSuggestions.isEmpty {
                            MentionSuggestionStrip(suggestions: mentionSuggestions) { insertMention($0) }
                        }
                        composer
                    }
                }
            }
            // Top inset: pinned bar (§16.3) below the header, then the "Join call"
            // banner when the group has a live call we're not in yet.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // §18.4: in-chat search bar with next/prev match navigation.
                    if showInChatSearch {
                        InChatSearchBar(
                            query: $inChatSearchQuery,
                            searching: inChatSearching,
                            matchCount: inChatMatches.count,
                            matchIndex: inChatMatchIndex,
                            onPrev: { Task { await stepMatch(-1) } },
                            onNext: { Task { await stepMatch(1) } },
                            onClose: { closeInChatSearch() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if showPinnedBar {
                        PinnedMessageBar(
                            pins: pinnedMessages,
                            cursor: pinnedCursor,
                            onTap: { tapPinnedBar() },
                            onClose: { closePinnedBar() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let info = activeCallInfo, callKit.activeCall?.id != info.callId {
                        JoinCallBanner(info: info) {
                            Task { await joinActiveCall(info) }
                        }
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
                    // §18.4: in-chat message search.
                    Button { openInChatSearch() } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 17))
                    }
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
        // §16.2: round-video recording overlay — an in-place overlay (NOT a
        // presentation) so the composer button's active hold gesture survives.
        .overlay {
            if recSession.isActive, recSession.mode == .video {
                VideoNoteRecordingOverlay(
                    recorder: noteRecorder,
                    session: recSession,
                    onFlip: { noteRecorder.flipCamera() },
                    onCancel: { cancelRecording() },
                    onSend: { finishAndSendRecording() }
                )
                .overlay(alignment: .bottomTrailing) {
                    if recSession.phase == .holding {
                        RecordingPadlock(progress: recSession.lockProgress, locked: false)
                            .padding(.trailing, 24)
                            .padding(.bottom, 150)
                    }
                }
            }
        }
        .overlay {
            if let target = menuTarget {
                MessageActionsOverlay(
                    message: target,
                    isMine: target.senderId == myId,
                    peerName: title,
                    canEdit: canEdit(target),
                    canPin: canPinHere && !target.isSystem && !target.isCallEvent,
                    pinned: isPinnedNow(target),
                    onReact: { emoji in
                        Task { await react(target, emoji: emoji) }
                        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
                    },
                    onReply: { replyingTo = target; isComposerFocused = true },
                    onCopy: { UIPasteboard.general.string = target.body },
                    onToggleStar: { Task { await toggleStar(target) } },
                    onEdit: { beginEdit(target) },
                    onPin: {
                        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
                        if isPinnedNow(target) {
                            unpinDialogId = target.id
                        } else {
                            pinDialogTarget = target
                        }
                    },
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
        // §18.4: debounce in-chat search queries.
        .onChange(of: inChatSearchQuery) { _, q in scheduleInChatSearch(q) }
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
        // §16.3: pin — groups choose notify/silent, DMs get a simple confirm.
        .klicSelectionSheet(
            isPresented: pinDialogBinding,
            title: isDirect
                ? String(localized: "Pin this message at the top of the chat?")
                : String(localized: "Pin message"),
            options: pinOptions
        ) { option in
            guard let m = pinDialogTarget else { return }
            pinDialogTarget = nil
            Task { await pin(m, notify: option.id == "notify") }
        }
        // §16.3: unpin always confirms.
        .klicSelectionSheet(
            isPresented: unpinDialogBinding,
            title: String(localized: "Unpin this message?"),
            options: [KlicSheetOption(id: "unpin", label: String(localized: "Unpin"), isDestructive: true)]
        ) { _ in
            guard let id = unpinDialogId else { return }
            unpinDialogId = nil
            Task { await unpin(messageId: id) }
        }
        .task {
            // §16.6: blocked-DM state comes from the existing blocks list.
            if isDirect { await blockStore.refreshIfNeeded() }
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
            await loadPinned()   // §16.3 — degrades to no bar on older servers
            // §18.4: jump to the message tapped in global search.
            if let target = initialJumpMessageId {
                await jumpToMessageHighlighting(target)
            }
            #if DEBUG
            applyDebugSeedIfRequested()
            #endif
        }
        // §16.2: auto-lock at 59s (both modes) and the 60s round-video cap.
        .onChange(of: recorder.elapsed) { _, elapsed in
            guard recSession.mode == .audio else { return }
            watchRecordingProgress(elapsed: elapsed, isVideo: false)
        }
        .onChange(of: noteRecorder.elapsed) { _, elapsed in
            guard recSession.mode == .video else { return }
            watchRecordingProgress(elapsed: elapsed, isVideo: true)
        }
        .onAppear { isComposerFocused = true }
        .onDisappear {
            emitTyping(false)
            if recSession.isActive { cancelRecording() }
            // Persist unsent text as this chat's draft (§10.4). Mid-edit, the
            // stashed pre-edit draft is what belongs to the composer.
            ChatDrafts.save(conversation.id, text: editingMessage == nil ? draft : draftBeforeEdit)
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
        // §16.4: live edits — swap the refreshed payload in place, no scroll jump.
        .onReceive(socket.$lastUpdatedMessage.compactMap { $0 }) { updated in
            guard updated.conversationId == conversation.id else { return }
            applyUpdatedMessage(updated)
        }
        // §16.3: live pin/unpin — refresh the bar + the bubble's pinned state.
        .onReceive(socket.$lastPinEvent.compactMap { $0 }) { event in
            guard event.conversationId == conversation.id else { return }
            handlePinEvent(event)
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

    private var pinDialogBinding: Binding<Bool> {
        Binding(get: { pinDialogTarget != nil }, set: { if !$0 { pinDialogTarget = nil } })
    }

    private var unpinDialogBinding: Binding<Bool> {
        Binding(get: { unpinDialogId != nil }, set: { if !$0 { unpinDialogId = nil } })
    }

    /// §16.3: groups choose between a notifying and a silent pin; DMs just confirm.
    private var pinOptions: [KlicSheetOption] {
        if isDirect {
            return [KlicSheetOption(id: "silent", label: String(localized: "Pin"))]
        }
        return [
            KlicSheetOption(id: "notify", label: String(localized: "Pin and notify all members")),
            KlicSheetOption(id: "silent", label: String(localized: "Only Pin")),
        ]
    }

    /// Pinned per the live list (socket-fresh) or the message's own payload flag.
    func isPinnedNow(_ message: Message) -> Bool {
        message.isPinned || pinnedMessages.contains { $0.id == message.id }
    }

    /// §16.3: the bar shows while pins exist, unless the user hid it (the latch
    /// clears when a different newest pin arrives).
    var showPinnedBar: Bool {
        guard let newest = pinnedMessages.last else { return false }
        return hiddenNewestPinId != newest.id
    }

    /// TAP → jump to the cursor's pin (+ highlight), then step to the previous pin
    /// for the next tap (cycling through all pins).
    func tapPinnedBar() {
        guard !pinnedMessages.isEmpty else { return }
        let index = min(pinnedCursor, pinnedMessages.count - 1)
        let target = pinnedMessages[index]
        Task { await jumpToMessageHighlighting(target.id) }
        pinnedCursor = (index - 1 + pinnedMessages.count) % pinnedMessages.count
    }

    /// × → unpin confirm when this user may unpin; otherwise hide the bar locally
    /// until a new pin arrives.
    func closePinnedBar() {
        let current = pinnedMessages.indices.contains(pinnedCursor)
            ? pinnedMessages[pinnedCursor] : pinnedMessages.last
        if canPinHere, let current {
            unpinDialogId = current.id
        } else {
            hiddenNewestPinId = pinnedMessages.last?.id
        }
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

extension ChatView {
    /// §16.6: unblock straight from the banner — the composer returns in place.
    func unblockPeer() async {
        guard let peer = directPeer, !unblocking else { return }
        unblocking = true
        defer { unblocking = false }
        try? await BlockStore.shared.unblock(userId: peer.id)
    }

    /// §16.6: flash the transient "Couldn't send" notice.
    func showSendFailedNotice() {
        withAnimation(.easeIn(duration: 0.15)) { sendFailedNotice = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) { sendFailedNotice = false }
        }
    }
}

/// §16.6: shown in place of the composer while the DM peer is blocked BY ME.
struct BlockedComposerBanner: View {
    let name: String
    let unblocking: Bool
    let onUnblock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "nosign")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KlicColor.textMuted)
            Text("You blocked \(name)")
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
                .lineLimit(1)
            Spacer()
            Button(action: onUnblock) {
                Text(unblocking ? String(localized: "Unblocking…") : String(localized: "Unblock"))
                    .font(KlicFont.headline(14))
                    .foregroundStyle(KlicColor.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(KlicColor.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(unblocking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(KlicColor.surface)
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
