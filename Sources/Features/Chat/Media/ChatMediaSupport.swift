import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ChatMediaGalleryItem: Identifiable, Hashable {
    let id: String
    let attachmentId: String
    let messageId: String
    let url: String
    let isVideo: Bool
    let caption: String
    let senderName: String
    let createdAt: String
    let reactions: [Reaction]
    let isMine: Bool
    let durationMs: Int?
    let thumbnailURL: String?
    /// Whether *I* starred the containing message (§10.9 star toggle/indicator).
    var starred: Bool = false
    /// Live-Photo motion metadata — known only for locally-picked assets (§10.9).
    var isLivePhoto: Bool = false
    /// The full attachment payload, needed for Forward's re-upload (§10.9).
    var attachment: Attachment? = nil
}

enum Media {
    /// What backs an attachment's bytes (§13.15): small payloads travel as in-memory
    /// Data; large ones (videos, arbitrary files) stay on disk and are STREAMED by
    /// URLSession's uploadTask(fromFile:) — never buffered whole.
    enum Payload {
        case data(Data)
        case file(URL)

        var byteCount: Int {
            switch self {
            case .data(let data): return data.count
            case .file(let url):
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.intValue ?? 0
            }
        }
    }

    static func upload(
        conversationId: String, kind: String, contentType: String, data: Data,
        width: Int? = nil, height: Int? = nil, durationMs: Int? = nil,
        waveform: Data? = nil, fileName: String? = nil
    ) async throws -> AttachmentDraft {
        try await upload(
            conversationId: conversationId, kind: kind, contentType: contentType,
            payload: .data(data), width: width, height: height, durationMs: durationMs,
            waveform: waveform, fileName: fileName, onProgress: { _ in })
    }

    /// Upload with real byte progress (§9.1) — drives the optimistic message pill.
    static func upload(
        conversationId: String, kind: String, contentType: String, payload: Payload,
        width: Int? = nil, height: Int? = nil, durationMs: Int? = nil,
        waveform: Data? = nil, fileName: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> AttachmentDraft {
        let byteSize = payload.byteCount
        let ticket = try await APIClient.shared.requestUpload(
            conversationId: conversationId, kind: kind, contentType: contentType, byteSize: byteSize)
        switch payload {
        case .data(let data):
            try await APIClient.shared.uploadData(
                data, to: ticket.uploadUrl, contentType: contentType, onProgress: onProgress)
        case .file(let url):
            try await APIClient.shared.uploadFile(
                url, to: ticket.uploadUrl, contentType: contentType, onProgress: onProgress)
        }
        return AttachmentDraft(
            key: ticket.key, kind: kind, contentType: contentType, byteSize: byteSize,
            width: width, height: height, durationMs: durationMs, waveform: waveform, fileName: fileName)
    }

    static func encodeImage(_ image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> (Data, Int, Int)? {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let maxSide = max(px.width, px.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let target = CGSize(width: max(px.width * scale, 1), height: max(px.height * scale, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }

    static func mime(for url: URL, fallback: String) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallback
    }

    /// Forward an existing attachment to other chats (§10.9): download the bytes once
    /// (or reuse the cached file), then upload + send per target conversation.
    /// §13.15: re-uploads stream straight from the cached file — no memory buffering.
    static func forwardAttachment(_ attachment: Attachment, to conversationIds: [String]) async throws {
        let local = try await AttachmentFileStore.shared.download(attachment)
        for conversationId in conversationIds {
            let draft = try await upload(
                conversationId: conversationId,
                kind: attachment.kind,
                contentType: attachment.contentType,
                payload: .file(local),
                width: attachment.width,
                height: attachment.height,
                durationMs: attachment.durationMs,
                fileName: attachment.fileName,
                onProgress: { _ in }
            )
            _ = try await APIClient.shared.sendMessage(
                conversationId: conversationId, body: nil, attachments: [draft], replyToId: nil
            )
            await MainActor.run { FrequentContacts.recordSend(conversationId: conversationId) }
        }
    }
}

struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vid-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    enum Mode {
        case photo
        case video
        /// §11.2: full capture from the attachment sheet's camera tile — the user can
        /// switch between photo and video inside the system camera UI.
        case photoOrVideo
    }

    let mode: Mode
    var onImage: ((UIImage) -> Void)? = nil
    var onVideo: ((URL) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Upload quality (§8.3): HD records/exports at high quality; Standard
        // keeps the previous medium-quality pipeline.
        let hd = UploadQuality.current == .hd
        switch mode {
        case .photo:
            picker.cameraCaptureMode = .photo
        case .video:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoQuality = hd ? .typeHigh : .typeMedium
            picker.videoExportPreset = hd ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
            // §13.16: video capture is first-class — long recordings are fine now
            // that uploads stream from disk (§13.15; server video cap 512MB).
            picker.videoMaximumDuration = 600
        case .photoOrVideo:
            picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            picker.cameraCaptureMode = .photo
            picker.videoQuality = hd ? .typeHigh : .typeMedium
            picker.videoExportPreset = hd ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
            picker.videoMaximumDuration = 600
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo?(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImage?(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
