import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

extension ChatView {
    var composer: some View {
        MessageComposer(
            conversationId: conversation.id,
            draft: $draft,
            focused: $isComposerFocused,
            recorder: recorder,
            recSession: recSession,
            uploading: uploading,
            hasPendingAttachments: !pendingMedia.isEmpty,
            // §15.1: the reply preview renders INSIDE the input container.
            replyPreview: replyingTo.map {
                ComposerReplyPreview(
                    authorName: $0.senderId == myId ? String(localized: "yourself") : title,
                    preview: previewText(for: $0)
                )
            },
            // §16.4: edit mode — banner + checkmark; wins over the reply banner.
            editPreview: editingMessage.map { ComposerEditPreview(original: $0.body) },
            editShakeTrigger: editShakeTrigger,
            onCancelReply: { withAnimation { replyingTo = nil } },
            onCancelEdit: { exitEdit() },
            onAttach: { showAttachMenu = true },
            onStickers: { showStickers = true },
            onSend: {
                if editingMessage != nil {
                    Task { await applyEdit() }
                } else {
                    Task { await sendComposerPayload() }
                }
            },
            // §16.2: TAP toggles audio ↔ video (mode persists per app session).
            onToggleCaptureMode: {
                recSession.setMode(recSession.mode == .audio ? .video : .audio)
            },
            onHoldStart: { holdStart() },
            onHoldDrag: { holdDrag($0) },
            onHoldEnd: { translation, velocity in holdEnd(translation, velocity) },
            onCancelRecording: { cancelRecording() },
            onSendRecording: { finishAndSendRecording() }
        )
        // ONE Klic attachment sheet with Gallery | Files tabs (§10.11/§11.2).
        // §14.2 crash fix: the follow-up cover (camera/picker/importer/scanner) is
        // presented from the sheet's onDismiss — AFTER the dismissal actually
        // completes — instead of a fixed 0.4s timer. On a slow frame the timer fired
        // while the sheet was still animating out, and presenting the camera cover
        // mid-dismissal corrupted the presentation stack (stuck/frozen capture flow).
        .sheet(isPresented: $showAttachMenu, onDismiss: { runPendingAttachAction() }) {
            KlicAttachmentSheet(
                onSendAssets: { assets in
                    // §13.17: an all-media bulk selection sends ONE message with
                    // multiple attachments (bento grid), via the upload-pill pipeline.
                    Task { await sendAssetsAsMessages(assets) }
                },
                onOpenSystemPicker: { pendingAttach = .photos },
                onOpenCamera: { pendingAttach = .camera },
                onSelectFiles: { pendingAttach = .file },
                onScanDocument: { pendingAttach = .scan }
            )
        }
        .fullScreenCover(isPresented: $showDocScanner) {
            DocumentScannerView { pdfURL in
                Task { await sendFile(pdfURL) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $showPhotos,
            selection: $pickedItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await stagePickedMedia(items); pickedItems = [] }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                mode: cameraMode,
                onImage: { img in Task { await stageImage(img) } },
                onVideo: { url in Task { await stageVideo(url) } }
            )
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await sendFile(url) } }
        }
        .sheet(isPresented: $showStickers) {
            stickersSheetContent
        }
    }

    /// The picker/camera/importer covers can't present while the attach sheet is still
    /// up — the chosen action is recorded in `pendingAttach` and executed by the
    /// sheet's onDismiss once the dismissal has fully completed (§14.2).
    func runPendingAttachAction() {
        guard let action = pendingAttach else { return }
        pendingAttach = nil
        switch action {
        case .photos: showPhotos = true
        case .camera:
            // §11.2/§14.2: the attachment sheet's camera captures photo AND video.
            cameraMode = .photoOrVideo
            showCamera = true
        case .file: showFileImporter = true
        case .scan: showDocScanner = true
        }
    }

    @ViewBuilder private var stickersSheetContent: some View {
        StickerPicker { id in
            showStickers = false
            Task { await sendSticker(id) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
