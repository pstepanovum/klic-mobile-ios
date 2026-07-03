import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

extension ChatView {
    var composer: some View {
        MessageComposer(
            draft: $draft,
            focused: $isComposerFocused,
            recorder: recorder,
            uploading: uploading,
            hasPendingAttachments: !pendingMedia.isEmpty,
            captureMode: $captureMode,
            onAttach: { showAttachMenu = true },
            onStickers: { showStickers = true },
            onSend: { Task { await sendComposerPayload() } },
            onToggleCaptureMode: {
                captureMode = captureMode == .audio ? .video : .audio
            },
            onHoldStart: {
                switch captureMode {
                case .audio:
                    recorder.start()
                case .video:
                    cameraMode = .video
                    showCamera = true
                }
            },
            onHoldEnd: {
                if captureMode == .audio {
                    Task { await stopAndSendVoice() }
                }
            },
            onCancelRecording: { recorder.cancel() },
            onSendVoice: { Task { await stopAndSendVoice() } }
        )
        // ONE Klic attachment sheet with Gallery | Files tabs (§10.11).
        .sheet(isPresented: $showAttachMenu) {
            KlicAttachmentSheet(
                onSendAssets: { assets in
                    Task { await stageAssets(assets) }
                },
                onOpenSystemPicker: { pendingAttach = .photos; deferAttachAction() },
                onOpenCamera: { pendingAttach = .camera; deferAttachAction() },
                onSelectFiles: { pendingAttach = .file; deferAttachAction() },
                onScanDocument: { pendingAttach = .scan; deferAttachAction() }
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
    /// up — run the chosen action right after it dismisses.
    private func deferAttachAction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let action = pendingAttach else { return }
            pendingAttach = nil
            switch action {
            case .photos: showPhotos = true
            case .camera:
                cameraMode = .photo
                showCamera = true
            case .file: showFileImporter = true
            case .scan: showDocScanner = true
            }
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
