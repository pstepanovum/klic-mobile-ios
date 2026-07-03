import SwiftUI
import PhotosUI
import Photos
import AVFoundation

/// Staging (preview-before-send) and uploading of photo/video/voice/file attachments.
/// Media sends are optimistic (§9.1): the composer clears immediately, an in-chat pill
/// tracks the real upload bytes, and the pill is swapped for the server message in
/// place when the send lands.
extension ChatView {
    func stagePickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let movie = try? await item.loadTransferable(type: Movie.self) {
                await stageVideo(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) {
                await stageImage(image)
            }
        }
    }

    /// Stage PHAssets picked from the attachment sheet's gallery grid (§10.11).
    /// Live-Photo assets are flagged so the pre-send flow can show the LIVE pill (§10.9).
    func stageAssets(_ assets: [PHAsset]) async {
        for asset in assets {
            if asset.mediaType == .video {
                if let url = await Self.exportVideoURL(asset) {
                    await stageVideo(url)
                }
            } else if asset.mediaType == .image {
                if let image = await Self.requestFullImage(asset) {
                    await stageImage(image)
                    if asset.mediaSubtypes.contains(.photoLive), let last = pendingMedia.indices.last {
                        pendingMedia[last].isLivePhoto = true
                    }
                }
            }
        }
    }

    private static func requestFullImage(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat   // single callback
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func exportVideoURL(_ asset: PHAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vid-\(UUID().uuidString).\(ext)")
                try? FileManager.default.copyItem(at: urlAsset.url, to: copy)
                continuation.resume(returning: FileManager.default.fileExists(atPath: copy.path) ? copy : nil)
            }
        }
    }

    @MainActor
    func stageImage(_ image: UIImage) async {
        // Upload quality (§8.3): HD keeps more pixels + lighter compression.
        let quality = UploadQuality.current
        guard let (data, w, h) = Media.encodeImage(
            image, maxDimension: quality.imageMaxDimension, quality: quality.imageJpegQuality
        ) else { return }
        pendingMedia.append(
            PendingMediaDraft(
                kind: "IMAGE",
                contentType: "image/jpeg",
                data: data,
                previewImage: image,
                width: w,
                height: h
            )
        )
    }

    @MainActor
    func stageVideo(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        let asset = AVURLAsset(url: url)
        var durationMs = 0
        if let duration = try? await asset.load(.duration) {
            durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        }
        var width: Int?
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize) {
            width = Int(abs(naturalSize.width))
            height = Int(abs(naturalSize.height))
        }
        guard let previewImage = videoThumbnail(for: asset) else { return }
        pendingMedia.append(
            PendingMediaDraft(
                kind: "VIDEO",
                contentType: Media.mime(for: url, fallback: "video/quicktime"),
                data: data,
                previewImage: previewImage,
                width: width,
                height: height,
                durationMs: durationMs,
                fileName: url.lastPathComponent
            )
        )
    }

    private func videoThumbnail(for asset: AVURLAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Files go straight into the optimistic upload pipeline (doc pill with progress).
    func sendFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let draft = PendingMediaDraft(
            kind: "FILE",
            contentType: Media.mime(for: url, fallback: "application/octet-stream"),
            data: data,
            previewImage: nil,
            fileName: url.lastPathComponent
        )
        await MainActor.run {
            startUpload(items: [draft], caption: "", replyToId: nil)
        }
    }

    func stopAndSendVoice() async {
        guard let (data, durationMs, waveform) = recorder.stop() else { return }
        await sendVoiceAttachment(data: data, durationMs: durationMs, waveform: waveform)
    }

    /// Text-only drafts go through send(); staged media becomes ONE optimistic upload
    /// pill (all staged items ride in a single message, like before).
    func sendComposerPayload() async {
        if pendingMedia.isEmpty {
            await send()
            return
        }
        let items = pendingMedia
        let caption = draft.trimmingCharacters(in: .whitespaces)
        let replyId = replyingTo?.id
        draft = ""
        pendingMedia.removeAll()
        withAnimation { replyingTo = nil }
        startUpload(items: items, caption: caption, replyToId: replyId)
    }

    /// Insert the optimistic pill and kick the transfer off. The chat stays fully
    /// interactive; concurrent uploads each own their pill and progress.
    @MainActor
    func startUpload(items: [PendingMediaDraft], caption: String, replyToId: String?) {
        let upload = OutgoingUpload(items: items, caption: caption, replyToId: replyToId)
        outgoingUploads.append(upload)
        scrollToBottom()
        Task { await performUpload(upload.id) }
    }

    func retryUpload(_ id: UUID) {
        guard let idx = outgoingUploads.firstIndex(where: { $0.id == id }) else { return }
        outgoingUploads[idx].failed = false
        outgoingUploads[idx].progress = 0
        Task { await performUpload(id) }
    }

    func discardUpload(_ id: UUID) {
        outgoingUploads.removeAll { $0.id == id }
    }

    /// Upload every item's bytes (aggregated real progress across the whole payload),
    /// then send the message and swap the pill for the server bubble in one update.
    func performUpload(_ id: UUID) async {
        guard let upload = outgoingUploads.first(where: { $0.id == id }) else { return }
        let totalBytes = max(upload.totalBytes, 1)
        var uploadedBytes = 0
        do {
            var drafts: [AttachmentDraft] = []
            for item in upload.items {
                let base = uploadedBytes
                let itemBytes = item.data.count
                let draft = try await Media.upload(
                    conversationId: conversation.id,
                    kind: item.kind,
                    contentType: item.contentType,
                    data: item.data,
                    width: item.width,
                    height: item.height,
                    durationMs: item.durationMs,
                    waveform: item.waveform,
                    fileName: item.fileName,
                    onProgress: { fraction in
                        let sent = base + Int(fraction * Double(itemBytes))
                        Task { @MainActor in
                            self.setUploadProgress(id, Double(sent) / Double(totalBytes))
                        }
                    }
                )
                drafts.append(draft)
                uploadedBytes += itemBytes
                setUploadProgress(id, Double(uploadedBytes) / Double(totalBytes))
            }
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: upload.caption.isEmpty ? nil : upload.caption,
                attachments: drafts,
                replyToId: upload.replyToId
            )
            // Replace in place: pill out, server bubble in, one state turn — no flash,
            // and the bottom-anchored list keeps its scroll position.
            outgoingUploads.removeAll { $0.id == id }
            upsert(msg)
            FrequentContacts.recordSend(conversationId: conversation.id)   // §10.4
            if atBottom { scrollToBottom(animated: false) }
        } catch {
            if let idx = outgoingUploads.firstIndex(where: { $0.id == id }) {
                outgoingUploads[idx].failed = true
            }
        }
    }

    private func setUploadProgress(_ id: UUID, _ value: Double) {
        guard let idx = outgoingUploads.firstIndex(where: { $0.id == id }) else { return }
        outgoingUploads[idx].progress = min(max(value, outgoingUploads[idx].progress), 1)
    }

    /// Voice notes keep the direct path (they're small and the recorder bar already
    /// gives feedback), but no longer block the composer.
    private func sendVoiceAttachment(data: Data, durationMs: Int, waveform: Data?) async {
        let replyId = replyingTo?.id
        do {
            let draft = try await Media.upload(
                conversationId: conversation.id, kind: "VOICE", contentType: "audio/m4a", data: data,
                durationMs: durationMs, waveform: waveform)
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id, body: nil, attachments: [draft], replyToId: replyId)
            withAnimation { replyingTo = nil }
            upsert(msg)
            scrollToBottom()
        } catch {
            // Upload/send failed — silently ignored for now (matches existing send() behavior).
        }
    }
}
