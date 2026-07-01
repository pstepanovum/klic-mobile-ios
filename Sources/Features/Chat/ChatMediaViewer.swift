import SwiftUI

struct MediaViewer: View {
    let items: [ChatMediaGalleryItem]
    let selectedAttachmentId: String
    let onClose: () -> Void
    let onReact: (String, String) -> Void
    let onDeleteForMe: (String) -> Void
    let onDeleteEveryone: (String) -> Void

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
    @State private var showShareDialog = false
    @State private var showDeleteDialog = false
    @State private var activityItems: [Any] = []

    @StateObject private var playerBox = MediaPlayerBox()

    init(
        items: [ChatMediaGalleryItem],
        selectedAttachmentId: String,
        onClose: @escaping () -> Void,
        onReact: @escaping (String, String) -> Void,
        onDeleteForMe: @escaping (String) -> Void,
        onDeleteEveryone: @escaping (String) -> Void
    ) {
        self.items = items
        self.selectedAttachmentId = selectedAttachmentId
        self.onClose = onClose
        self.onReact = onReact
        self.onDeleteForMe = onDeleteForMe
        self.onDeleteEveryone = onDeleteEveryone
        _currentAttachmentId = State(initialValue: selectedAttachmentId)
    }

    private var currentItem: ChatMediaGalleryItem? {
        items.first(where: { $0.attachmentId == currentAttachmentId }) ?? items.first
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(Double(abs(dragDismiss)) / 500, 0.7))
                .ignoresSafeArea()

            if let item = currentItem {
                VStack(spacing: 0) {
                    MediaViewerTopBar(
                        senderName: item.senderName,
                        timestamp: viewerTimestamp(item.createdAt),
                        onBack: onClose
                    )

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

                    mediaStage(item)

                    MediaViewerBottomPanel(
                        item: item,
                        items: items,
                        currentAttachmentId: currentAttachmentId,
                        isPlaying: playerBox.isPlaying,
                        onReact: onReact,
                        onSelectItem: { currentAttachmentId = $0 },
                        onShare: { showShareDialog = true },
                        onPlayPause: { if item.isVideo { playerBox.toggle() } },
                        onDelete: { showDeleteDialog = true }
                    )
                }
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
            syncPlayerForCurrentItem()
        }
        .confirmationDialog("Share media", isPresented: $showShareDialog, titleVisibility: .visible) {
            Button("Save") { saveCurrentMedia() }
            Button("Share") { prepareNativeShare() }
            Button("Forward") { }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete message?", isPresented: $showDeleteDialog, titleVisibility: .visible) {
            if let item = currentItem {
                Button("Delete for me", role: .destructive) {
                    onDeleteForMe(item.messageId)
                    onClose()
                }
                if item.isMine {
                    Button("Delete for everyone", role: .destructive) {
                        onDeleteEveryone(item.messageId)
                        onClose()
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: activityItems)
        }
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
                .onTapGesture { playerBox.toggle() }
            } else if let imageURL = URL(string: item.url) {
                RemoteImage(url: imageURL) { phase in
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
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.3)) { toggleZoom() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if item.isVideo {
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

    private func saveCurrentMedia() {
        guard let item = currentItem, let url = URL(string: item.url) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            await MainActor.run {
                if item.isVideo {
                    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(item.attachmentId).mp4")
                    try? data.write(to: fileURL, options: .atomic)
                    UISaveVideoAtPathToSavedPhotosAlbum(fileURL.path, nil, nil, nil)
                } else if let image = UIImage(data: data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                }
            }
        }
    }

    private func prepareNativeShare() {
        guard let item = currentItem, let url = URL(string: item.url) else { return }
        activityItems = [url]
        showShareSheet = true
    }
}
