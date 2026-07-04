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
        /// switch between photo and video inside the system camera UI (§14.2: the
        /// Photo | Video selector is the system camera's own mode control, enabled by
        /// declaring both media types).
        case photoOrVideo
    }

    let mode: Mode
    var onImage: ((UIImage) -> Void)? = nil
    var onVideo: ((URL) -> Void)? = nil

    /// §14.2 crash fix: the capture flow ends through THIS dismiss action, so the
    /// `showCamera` presentation binding is always reset. The old delegate called
    /// `picker.dismiss(animated:)` on the UIKit controller directly, which left
    /// SwiftUI's fullScreenCover binding stuck at `true`; the next state change
    /// re-evaluated the body against a presentation SwiftUI no longer tracked and
    /// froze (or crashed) the capture flow.
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        // §14.2 crash fix: `sourceType = .camera` throws NSInvalidArgumentException
        // on hardware without a camera (the simulator) — never set it unguarded.
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return CameraUnavailableController(onClose: { dismiss() })
        }
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
            // Both media types → the system camera shows its Photo | Video mode
            // switcher; either capture flows through the same delegate.
            picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            picker.cameraCaptureMode = .photo
            picker.videoQuality = hd ? .typeHigh : .typeMedium
            picker.videoExportPreset = hd ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
            picker.videoMaximumDuration = 600
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                // The picker deletes its temp recording after dismissal — hand the
                // staging pipeline its own copy.
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cam-\(UUID().uuidString).\(ext)")
                try? FileManager.default.copyItem(at: url, to: copy)
                parent.onVideo?(FileManager.default.fileExists(atPath: copy.path) ? copy : url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImage?(image)
            }
            // Dismiss through SwiftUI so the presentation binding resets (see above).
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Klic-styled fallback for devices without a camera (§14.2) — shown instead of
/// crashing when UIImagePickerController's camera source is unavailable.
private final class CameraUnavailableController: UIViewController {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let icon = UIImageView(image: UIImage(systemName: "camera.on.rectangle"))
        icon.tintColor = .white.withAlphaComponent(0.85)
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = String(localized: "No camera is available on this device.")
        label.textColor = .white.withAlphaComponent(0.85)
        label.font = UIFont(name: "TikTokSans-Regular", size: 16) ?? .systemFont(ofSize: 16)
        label.numberOfLines = 0
        label.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.title = String(localized: "Close")
        config.baseBackgroundColor = .white.withAlphaComponent(0.16)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 26, bottom: 10, trailing: 26)
        let button = UIButton(configuration: config, primaryAction: UIAction { [onClose] _ in onClose() })

        let stack = UIStackView(arrangedSubviews: [icon, label, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            icon.heightAnchor.constraint(equalToConstant: 44),
            icon.widthAnchor.constraint(equalToConstant: 56),
        ])
    }
}
