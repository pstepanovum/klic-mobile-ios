import SwiftUI

/// Full-screen media viewer (§10.9): strict kind-based rendering (images never get a
/// Play overlay), single-tap immersive mode, working Klic-styled footer actions
/// (Share / Forward / Star / Reply / Delete), and a LIVE / duration pill top-left.
struct MediaViewer: View {
    let items: [ChatMediaGalleryItem]
    let selectedAttachmentId: String
    let onClose: () -> Void
    let onReact: (String, String) -> Void
    let onDeleteForMe: (String) -> Void
    let onDeleteEveryone: (String) -> Void
    var onToggleStar: (String) -> Void = { _ in }
    var onReply: (String) -> Void = { _ in }

    @State private var currentAttachmentId: String
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDismiss: CGFloat = 0
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackRate: Float = 1
    @State private var showShareSheet = false
    @State private var showDeleteDialog = false
    @State private var showForwardPicker = false
    @State private var activityItems: [Any] = []
    @State private var preparingShare = false
    /// §10.9: single tap hides the top bar + footer (and video controls).
    @State private var immersive = false
    @State private var forwardToast: String?

    @StateObject private var playerBox = MediaPlayerBox()

    init(
        items: [ChatMediaGalleryItem],
        selectedAttachmentId: String,
        onClose: @escaping () -> Void,
        onReact: @escaping (String, String) -> Void,
        onDeleteForMe: @escaping (String) -> Void,
        onDeleteEveryone: @escaping (String) -> Void,
        onToggleStar: @escaping (String) -> Void = { _ in },
        onReply: @escaping (String) -> Void = { _ in }
    ) {
        self.items = items
        self.selectedAttachmentId = selectedAttachmentId
        self.onClose = onClose
        self.onReact = onReact
        self.onDeleteForMe = onDeleteForMe
        self.onDeleteEveryone = onDeleteEveryone
        self.onToggleStar = onToggleStar
        self.onReply = onReply
        _currentAttachmentId = State(initialValue: selectedAttachmentId)
    }

    private var currentItem: ChatMediaGalleryItem? {
        items.first(where: { $0.attachmentId == currentAttachmentId }) ?? items.first
    }

    /// §10.9: the media that belongs to the SAME message as the current item — the set
    /// the horizontal pager swipes across (a message's own image gallery). Jumping to
    /// another message via the thumbnail strip re-scopes the pager to that message.
    private var currentGroupItems: [ChatMediaGalleryItem] {
        guard let messageId = currentItem?.messageId else { return items }
        let group = items.filter { $0.messageId == messageId }
        return group.isEmpty ? items : group
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(Double(abs(dragDismiss)) / 500, 0.7))
                .ignoresSafeArea()

            if let item = currentItem {
                VStack(spacing: 0) {
                    if !immersive {
                        MediaViewerTopBar(
                            senderName: item.senderName,
                            timestamp: viewerTimestamp(item.createdAt),
                            onBack: onClose
                        )

                        // LIVE / duration pill under the back button (§10.9). Live-Photo
                        // metadata is only known for locally-picked assets — hidden otherwise.
                        if let badge = mediaBadge(item) {
                            HStack {
                                badge
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                        }

                        // Strictly keyed on the attachment kind — images never get video UI.
                        if item.isVideo {
                            MediaViewerVideoControls(
                                currentTime: $currentTime,
                                duration: duration,
                                playbackRate: $playbackRate,
                                onSeek: { playerBox.seek(to: $0) },
                                onRateChange: { playerBox.setRate($0) },
                                onPictureInPicture: { playerBox.startPictureInPicture() }
                            )
                        }
                    }

                    mediaPager

                    if !immersive {
                        MediaViewerBottomPanel(
                            item: item,
                            items: items,
                            currentAttachmentId: currentAttachmentId,
                            isPlaying: playerBox.isPlaying,
                            preparingShare: preparingShare,
                            onReact: onReact,
                            onSelectItem: { currentAttachmentId = $0 },
                            onShare: { Task { await prepareShare() } },
                            onForward: { showForwardPicker = true },
                            onToggleStar: { onToggleStar(item.messageId) },
                            onReply: {
                                onReply(item.messageId)
                                onClose()
                            },
                            onPlayPause: { if item.isVideo { playerBox.toggle() } },
                            onDelete: { showDeleteDialog = true }
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: immersive)
            }

            if let forwardToast {
                Text(forwardToast)
                    .font(KlicFont.medium(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 110)
                    .transition(.opacity)
            }
        }
        .onAppear { syncPlayerForCurrentItem() }
        .onDisappear { playerBox.stop() }
        .onChange(of: currentAttachmentId) { _, _ in
            resetImageState()
            syncPlayerForCurrentItem()
        }
        .onChange(of: items) { _, _ in
            if currentItem == nil, let first = items.first {
                currentAttachmentId = first.attachmentId
            }
        }
        .klicSelectionSheet(
            isPresented: $showDeleteDialog,
            title: String(localized: "Delete message"),
            options: deleteOptions
        ) { option in
            guard let item = currentItem else { return }
            if option.id == "me" {
                onDeleteForMe(item.messageId)
                onClose()
            } else if option.id == "everyone" {
                onDeleteEveryone(item.messageId)
                onClose()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: activityItems)
        }
        .sheet(isPresented: $showForwardPicker) {
            ForwardPickerSheet { conversationIds in
                Task { await forward(to: conversationIds) }
            }
        }
    }

    private var deleteOptions: [KlicSheetOption] {
        var options = [KlicSheetOption(id: "me", label: String(localized: "Delete for me"), isDestructive: true)]
        if currentItem?.isMine == true {
            options.append(KlicSheetOption(id: "everyone", label: String(localized: "Delete for everyone"), isDestructive: true))
        }
        return options
    }

    private func mediaBadge(_ item: ChatMediaGalleryItem) -> AnyView? {
        if item.isVideo, let ms = item.durationMs, ms > 0 {
            return AnyView(
                Text(Self.durationText(ms))
                    .font(KlicFont.caption(11).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
            )
        }
        if !item.isVideo, item.isLivePhoto {
            return AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "livephoto")
                        .font(.system(size: 10, weight: .semibold))
                    Text("LIVE")
                        .font(KlicFont.caption(10).weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
            )
        }
        return nil
    }

    static func durationText(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Horizontal paging across the current message's media, starting at the tapped
    /// item. Each page keeps its own pinch-zoom / vertical drag-to-dismiss (those live
    /// in `mediaStage`); the TabView owns the left/right swipe and the page-dot
    /// indicator. Single-image messages page to nothing and show no dots.
    private var mediaPager: some View {
        TabView(selection: $currentAttachmentId) {
            ForEach(currentGroupItems) { groupItem in
                mediaStage(groupItem)
                    .tag(groupItem.attachmentId)
            }
        }
        .tabViewStyle(
            .page(indexDisplayMode: currentGroupItems.count > 1 && !immersive ? .always : .never)
        )
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
    }

    @ViewBuilder
    private func mediaStage(_ item: ChatMediaGalleryItem) -> some View {
        ZStack {
            if item.isVideo {
                VideoCanvasView(
                    player: playerBox.player,
                    onPiPReady: { controller in playerBox.bindPiP(controller) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Single tap toggles immersive; controls come back on tap (§10.9).
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { immersive.toggle() } }
            } else if let imageURL = URL(string: item.url) {
                RemoteImage(url: imageURL, cacheKey: RemoteImageStore.attachmentCacheKey(item.attachmentId)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color.black.overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.7)))
                    default:
                        LoadingCircle(color: .white)
                    }
                }
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dragDismiss)
                .gesture(magnification)
                .simultaneousGesture(dragGesture)
                // Double-tap zoom unchanged; single tap toggles immersive (§10.9).
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.3)) { toggleZoom() } }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { immersive.toggle() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Center play/pause — VIDEO ONLY, and hidden while immersive.
            if item.isVideo, !immersive {
                Button { playerBox.toggle() } label: {
                    Image(systemName: playerBox.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 74, height: 74)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value, 5))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    dragDismiss = value.translation.height
                }
            }
            .onEnded { _ in
                if scale > 1 {
                    lastOffset = offset
                } else if abs(dragDismiss) > 140 {
                    onClose()
                } else {
                    withAnimation(.spring()) { dragDismiss = 0 }
                }
            }
    }

    private func toggleZoom() {
        if scale > 1 {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        } else {
            scale = 2.5
            lastScale = 2.5
        }
    }

    private func viewerTimestamp(_ iso: String) -> String {
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        guard let date = primary.date(from: iso) ?? fallback.date(from: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func resetImageState() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
        dragDismiss = 0
    }

    private func syncPlayerForCurrentItem() {
        guard let item = currentItem else { return }
        if item.isVideo, let url = URL(string: item.url) {
            playerBox.load(url: url, rate: playbackRate)
            currentTime = 0
            duration = Double(item.durationMs ?? 0) / 1000
            playerBox.onProgress = { time, total in
                currentTime = time
                if total > 0 {
                    duration = total
                }
            }
        } else {
            playerBox.stop()
            currentTime = 0
            duration = 0
        }
    }

    /// Share the media FILE (downloaded locally) via the system share sheet (§10.9).
    private func prepareShare() async {
        guard let item = currentItem else { return }
        preparingShare = true
        defer { preparingShare = false }
        if let attachment = item.attachment,
           let local = try? await AttachmentFileStore.shared.download(attachment) {
            activityItems = [local]
            showShareSheet = true
            return
        }
        // Fallback: raw bytes into a temp file named by kind.
        guard let url = URL(string: item.url),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let ext = item.isVideo ? "mp4" : "jpg"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.attachmentId).\(ext)")
        try? data.write(to: file, options: .atomic)
        activityItems = [file]
        showShareSheet = true
    }

    private func forward(to conversationIds: [String]) async {
        guard let attachment = currentItem?.attachment, !conversationIds.isEmpty else { return }
        do {
            try await Media.forwardAttachment(attachment, to: conversationIds)
            withAnimation { forwardToast = String(localized: "Forwarded") }
        } catch {
            withAnimation { forwardToast = String(localized: "Couldn't forward the media.") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { forwardToast = nil }
        }
    }
}
