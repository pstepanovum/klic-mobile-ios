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
            if let draft = await makeAssetDraft(asset) {
                pendingMedia.append(draft)
            }
        }
    }

    /// Bulk send from the attachment sheet's "Send N" pill. §13.17: an all-media
    /// selection (the gallery grid only offers images/videos; the sheet caps picks
    /// at 10) travels as ONE message with multiple attachments, rendered as a bento
    /// grid in a single bubble. Drafts are built in the exact pick order.
    @MainActor
    func sendAssetsAsMessages(_ assets: [PHAsset]) async {
        var drafts: [PendingMediaDraft] = []
        for asset in assets {
            if let draft = await makeAssetDraft(asset) {
                drafts.append(draft)
            }
        }
        guard !drafts.isEmpty else { return }
        startUpload(items: drafts, caption: "", replyToId: nil)
    }

    /// One PHAsset → a ready-to-send draft (image or exported video).
    @MainActor
    private func makeAssetDraft(_ asset: PHAsset) async -> PendingMediaDraft? {
        if asset.mediaType == .video {
            guard let url = await Self.exportVideoURL(asset) else { return nil }
            return await makeVideoDraft(url)
        }
        if asset.mediaType == .image {
            guard let image = await Self.requestFullImage(asset) else { return nil }
            var draft = await makeImageDraft(image)
            if asset.mediaSubtypes.contains(.photoLive) { draft?.isLivePhoto = true }
            return draft
        }
        return nil
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
        if let draft = await makeImageDraft(image) {
            pendingMedia.append(draft)
        }
    }

    @MainActor
    func stageVideo(_ url: URL) async {
        if let draft = await makeVideoDraft(url) {
            pendingMedia.append(draft)
        }
    }

    /// §14.2: the JPEG re-encode of a full-resolution capture takes hundreds of ms —
    /// it runs OFF the main actor so staging a photo never stalls a dismissal
    /// animation (part of the camera freeze fix).
    func makeImageDraft(_ image: UIImage) async -> PendingMediaDraft? {
        // Upload quality (§8.3): HD keeps more pixels + lighter compression.
        let quality = UploadQuality.current
        let encoded = await Task.detached(priority: .userInitiated) {
            Media.encodeImage(image, maxDimension: quality.imageMaxDimension, quality: quality.imageJpegQuality)
        }.value
        guard let (data, w, h) = encoded else { return nil }
        return PendingMediaDraft(
            kind: "IMAGE",
            contentType: "image/jpeg",
            data: data,
            previewImage: image,
            width: w,
            height: h
        )
    }

    @MainActor
    func makeVideoDraft(_ url: URL) async -> PendingMediaDraft? {
        // §13.15: videos stay on disk and are streamed at upload time — a
        // multi-hundred-MB recording must never be buffered into memory.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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
        guard let previewImage = videoThumbnail(for: asset) else { return nil }
        return PendingMediaDraft(
            kind: "VIDEO",
            contentType: Media.mime(for: url, fallback: "video/quicktime"),
            fileURL: url,
            previewImage: previewImage,
            width: width,
            height: height,
            durationMs: durationMs,
            fileName: url.lastPathComponent
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
    /// §13.15: the file is copied into the app's temp dir (the security scope on the
    /// picked URL doesn't outlive this call) and STREAMED from disk at upload time.
    func sendFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            return
        }
        let draft = PendingMediaDraft(
            kind: "FILE",
            contentType: Media.mime(for: url, fallback: "application/octet-stream"),
            fileURL: copy,
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
    /// interactive; concurrent uploads each own their pill and progress. §14.2: the
    /// pill lives in the UploadCenter registry, so it survives leaving this chat.
    @MainActor
    func startUpload(items: [PendingMediaDraft], caption: String, replyToId: String?) {
        uploadCenter.start(items: items, caption: caption, replyToId: replyToId, in: conversation.id)
        scrollToBottom()
    }

    func retryUpload(_ id: UUID) {
        uploadCenter.retry(id, in: conversation.id)
    }

    func discardUpload(_ id: UUID) {
        uploadCenter.discard(id, in: conversation.id)
    }

    /// Human-readable upload failure: server-provided text (size cap, bad type…)
    /// when we have it, a network hint otherwise.
    static func uploadFailureReason(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .server(let message, _) where !message.isEmpty:
                return message
            default:
                return String(localized: "Couldn't reach the server. Check your connection and retry.")
            }
        }
        if error is URLError {
            return String(localized: "Couldn't reach the server. Check your connection and retry.")
        }
        return String(localized: "Upload failed. Please try again.")
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
