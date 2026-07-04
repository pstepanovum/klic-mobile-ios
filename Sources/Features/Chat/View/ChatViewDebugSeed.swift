#if DEBUG
import Foundation

/// Debug-only UI seed (simulator verification): launching with
/// `KLIC_UI_SEED=1` appends locally-constructed §16 states to the opened chat —
/// a reply card with a media thumbnail, a round video message, an edited bubble,
/// and a couple of pinned previews — so the new visuals are verifiable before
/// the v0.3.19 server fields exist in prod. Local-only; nothing is sent.
extension ChatView {
    var debugSeedEnabled: Bool {
        ProcessInfo.processInfo.environment["KLIC_UI_SEED"] == "1"
    }

    func applyDebugSeedIfRequested() {
        guard debugSeedEnabled, let myId else { return }
        let now = ISO8601DateFormatter().string(from: Date())

        // Reuse a real attachment from the loaded history so thumbnails/plays work.
        let video = messages.flatMap(\.attachments).first { $0.isVideo }
        let image = messages.flatMap(\.attachments).first { $0.isImage }
        let visual = image ?? video

        var seeded: [Message] = []

        if let visual {
            // §16.1: reply card with a media thumbnail (own bubble).
            let stub = ReplyAttachmentStub(
                id: visual.id, kind: visual.kind, url: visual.url,
                contentType: visual.contentType, width: visual.width,
                height: visual.height, durationMs: visual.durationMs,
                fileName: visual.fileName
            )
            seeded.append(Message(
                id: "debug-reply-media", conversationId: conversation.id, senderId: myId,
                body: "Love this one — where was it taken?", kind: "TEXT", createdAt: now,
                status: "read",
                replyTo: ReplyPreview(
                    id: messages.first { m in m.attachments.contains { $0.id == visual.id } }?.id ?? "debug-parent",
                    senderId: conversation.members.first?.id ?? myId,
                    kind: visual.kind,
                    preview: visual.isVideo ? "🎥 Video" : "📷 Photo",
                    attachment: stub
                )
            ))
        }

        if let video {
            // §16.2: circular playback bubble (incoming) backed by a real video.
            seeded.append(Message(
                id: "debug-video-note", conversationId: conversation.id,
                senderId: conversation.members.first?.id ?? myId,
                body: "", kind: "VIDEO_NOTE", createdAt: now,
                attachments: [Attachment(
                    id: "debug-video-note-att", kind: "VIDEO_NOTE", url: video.url,
                    contentType: "video/mp4", byteSize: video.byteSize,
                    width: 400, height: 400, durationMs: video.durationMs,
                    waveform: nil, fileName: nil
                )]
            ))
        }

        // §16.4: edited meta in the tucked placement (own bubble).
        seeded.append(Message(
            id: "debug-edited", conversationId: conversation.id, senderId: myId,
            body: "Fixed the typo in this message", kind: "TEXT", createdAt: now,
            status: "read", editedAt: now
        ))

        messages.append(contentsOf: seeded)

        // §16.3: pinned bar with multiple pins built from real history.
        let textParents = messages.filter { !$0.body.isEmpty && !$0.isDeleted }.suffix(2)
        let pins: [ReplyPreview] = textParents.map {
            ReplyPreview(id: $0.id, senderId: $0.senderId, kind: $0.kind,
                         preview: $0.body, attachment: nil)
        }
        if !pins.isEmpty {
            setPinnedMessages(pins)
        }
    }
}
#endif
