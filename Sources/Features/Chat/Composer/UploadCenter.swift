import SwiftUI
import Combine

/// Session-scoped registry of in-flight attachment sends, keyed by conversation
/// (§14.2). Uploads always continued in the background; what used to be lost was the
/// PILL — it lived in ChatView @State and died with the view. The registry owns the
/// pills instead: leaving and re-entering a chat mid-upload re-attaches its progress
/// pill, and a send that completes while the chat is closed still resolves into the
/// real message (open chats upsert it via `completions`; the socket echo reconciles
/// the conversation list as before).
@MainActor
final class UploadCenter: ObservableObject {
    static let shared = UploadCenter()

    /// conversationId → its in-flight (or failed, awaiting retry/discard) uploads.
    @Published private(set) var uploadsByConversation: [String: [OutgoingUpload]] = [:]

    /// The server message each finished upload resolved to — an open chat for that
    /// conversation upserts it in the same turn the pill disappears (no flash).
    let completions = PassthroughSubject<Message, Never>()

    func uploads(in conversationId: String) -> [OutgoingUpload] {
        uploadsByConversation[conversationId] ?? []
    }

    /// Insert the optimistic pill and kick the transfer off.
    func start(items: [PendingMediaDraft], caption: String, replyToId: String?, in conversationId: String) {
        let upload = OutgoingUpload(items: items, caption: caption, replyToId: replyToId)
        uploadsByConversation[conversationId, default: []].append(upload)
        Task { await perform(upload.id, in: conversationId) }
    }

    func retry(_ id: UUID, in conversationId: String) {
        guard let idx = index(of: id, in: conversationId) else { return }
        uploadsByConversation[conversationId]?[idx].failed = false
        uploadsByConversation[conversationId]?[idx].errorText = nil
        uploadsByConversation[conversationId]?[idx].progress = 0
        Task { await perform(id, in: conversationId) }
    }

    func discard(_ id: UUID, in conversationId: String) {
        uploadsByConversation[conversationId]?.removeAll { $0.id == id }
        if uploadsByConversation[conversationId]?.isEmpty == true {
            uploadsByConversation[conversationId] = nil
        }
    }

    /// Upload every item's bytes (aggregated real progress across the whole payload),
    /// then send the message and resolve the pill into the server bubble.
    private func perform(_ id: UUID, in conversationId: String) async {
        guard let upload = uploads(in: conversationId).first(where: { $0.id == id }) else { return }
        let totalBytes = max(upload.totalBytes, 1)
        var uploadedBytes = 0
        do {
            var drafts: [AttachmentDraft] = []
            for item in upload.items {
                let base = uploadedBytes
                let itemBytes = item.byteCount
                // §13.15: disk-backed payloads (videos, files) STREAM from their temp
                // file; only small in-memory payloads (images, voice) travel as Data.
                let payload: Media.Payload
                if let fileURL = item.fileURL {
                    payload = .file(fileURL)
                } else if let data = item.data {
                    payload = .data(data)
                } else {
                    continue
                }
                let draft = try await Media.upload(
                    conversationId: conversationId,
                    kind: item.kind,
                    contentType: item.contentType,
                    payload: payload,
                    width: item.width,
                    height: item.height,
                    durationMs: item.durationMs,
                    waveform: item.waveform,
                    fileName: item.fileName,
                    onProgress: { fraction in
                        let sent = base + Int(fraction * Double(itemBytes))
                        Task { @MainActor in
                            self.setProgress(id, in: conversationId, Double(sent) / Double(totalBytes))
                        }
                    }
                )
                drafts.append(draft)
                uploadedBytes += itemBytes
                setProgress(id, in: conversationId, Double(uploadedBytes) / Double(totalBytes))
            }
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversationId,
                body: upload.caption.isEmpty ? nil : upload.caption,
                attachments: drafts,
                replyToId: upload.replyToId
            )
            // §14.2: seed the video-thumbnail cache from the local first frames we
            // already generated at send time, so the server bubble paints instantly.
            seedVideoThumbnails(items: upload.items, message: msg)
            // Replace in place: pill out, server bubble in, one state turn.
            discard(id, in: conversationId)
            completions.send(msg)
            FrequentContacts.recordSend(conversationId: conversationId)   // §10.4
        } catch {
            guard let idx = index(of: id, in: conversationId) else { return }
            uploadsByConversation[conversationId]?[idx].failed = true
            // §13.15: surface the REAL failure reason — the server's message for
            // policy rejections (size cap etc.) vs a network explanation.
            uploadsByConversation[conversationId]?[idx].errorText = ChatView.uploadFailureReason(error)
        }
    }

    /// Match the sent drafts to the returned attachments (same order) and cache each
    /// video's local first-frame under its server attachment id (§14.2).
    private func seedVideoThumbnails(items: [PendingMediaDraft], message: Message) {
        // Both VIDEO and VIDEO_NOTE carry a locally-generated first-frame preview;
        // a VIDEO-only filter dropped every video-note thumbnail (black circle bug).
        let videoItems = items.filter { $0.kind == "VIDEO" || $0.kind == "VIDEO_NOTE" }
        let videoAttachments = message.attachments.filter { $0.isVideoLike }
        for (item, attachment) in zip(videoItems, videoAttachments) {
            guard let preview = item.previewImage else { continue }
            Task { await VideoThumbnailer.store(preview, attachmentId: attachment.id) }
        }
    }

    private func setProgress(_ id: UUID, in conversationId: String, _ value: Double) {
        guard let idx = index(of: id, in: conversationId) else { return }
        let current = uploadsByConversation[conversationId]?[idx].progress ?? 0
        uploadsByConversation[conversationId]?[idx].progress = min(max(value, current), 1)
    }

    private func index(of id: UUID, in conversationId: String) -> Int? {
        uploadsByConversation[conversationId]?.firstIndex { $0.id == id }
    }
}
