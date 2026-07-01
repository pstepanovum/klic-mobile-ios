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
        .sheet(isPresented: $showAttachMenu) {
            AttachSheet(
                onPhotos: { pendingAttach = .photos; showAttachMenu = false },
                onCamera: { pendingAttach = .camera; showAttachMenu = false },
                onFile:   { pendingAttach = .file;   showAttachMenu = false }
            )
            .presentationDetents([.height(210)])
            .presentationDragIndicator(.visible)
            .presentationBackground(KlicColor.surface)
        }
        .onChange(of: showAttachMenu) { _, showing in
            if !showing, let action = pendingAttach {
                pendingAttach = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    switch action {
                    case .photos: showPhotos = true
                    case .camera:
                        cameraMode = .photo
                        showCamera = true
                    case .file:   showFileImporter = true
                    }
                }
            }
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
            StickerPicker { id in
                showStickers = false
                Task { await sendSticker(id) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
