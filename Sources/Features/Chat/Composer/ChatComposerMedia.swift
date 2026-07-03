import SwiftUI
import UIKit

struct PendingMediaDraft: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let contentType: String
    let data: Data
    /// Local preview for images/videos; nil for plain files (doc placeholder shown).
    let previewImage: UIImage?
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var waveform: Data?
    var fileName: String?
    /// Live-Photo motion metadata — known only for assets picked via the gallery
    /// grid (§10.9/§10.11); drives the "LIVE" pill in the pre-send flow.
    var isLivePhoto: Bool = false
}

/// One optimistic in-flight attachment send (§9.1). Rendered as a message pill at the
/// bottom of the chat with a real byte-progress ring; several can run concurrently,
/// each tracking its own bytes. Failed sends keep the pill with retry/discard.
struct OutgoingUpload: Identifiable {
    let id = UUID()
    let items: [PendingMediaDraft]
    let caption: String
    let replyToId: String?
    var progress: Double = 0
    var failed = false

    var totalBytes: Int { items.reduce(0) { $0 + $1.data.count } }
    var isFileOnly: Bool { items.allSatisfy { $0.previewImage == nil } }
}

struct PendingMediaComposerBar: View {
    let items: [PendingMediaDraft]
    let onRemove: (UUID) -> Void
    /// Opens the pre-send media editor (§10.9) for this staged item.
    var onEdit: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = item.previewImage {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                ZStack {
                                    KlicColor.surfaceRaised
                                    VStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(KlicColor.primary)
                                        Text(item.fileName ?? "File")
                                            .font(KlicFont.caption(9))
                                            .foregroundStyle(KlicColor.textMuted)
                                            .lineLimit(1)
                                            .padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        if item.kind == "VIDEO" {
                            Image(systemName: "video.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.6), in: Circle())
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        if item.isLivePhoto {
                            HStack(spacing: 2) {
                                Image(systemName: "livephoto")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("LIVE")
                                    .font(KlicFont.caption(8).weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }

                        // Edit (pencil) → pre-send media editor (§10.9).
                        if item.kind == "IMAGE" || item.kind == "VIDEO" {
                            Button { onEdit(item.id) } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.black.opacity(0.6), in: Circle())
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }

                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .padding(6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .padding(.bottom, 4)
        .background(KlicColor.background)
    }
}

// MARK: - Optimistic upload pill (§9.1)

/// The outgoing-message pill an upload renders as while its bytes are in flight:
/// local media preview with a byte-progress ring (files show a doc row with the same
/// ring), the caption below, and retry/discard affordances on failure. It's replaced
/// in place by the real server bubble when the send lands.
struct UploadingMessageBubble: View {
    let upload: OutgoingUpload
    let onRetry: () -> Void
    let onDiscard: () -> Void

    private let cardWidth: CGFloat = 240

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                if upload.isFileOnly {
                    fileCard
                } else {
                    mediaCard
                }
                if upload.failed {
                    failureActions
                }
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let preview = upload.items.first(where: { $0.previewImage != nil })?.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth - 8, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Color.black.opacity(0.25)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                progressOverlay
                if upload.items.count > 1 {
                    Text("+\(upload.items.count - 1)")
                        .font(KlicFont.caption(12).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
            .frame(width: cardWidth - 8, height: previewHeight)
            .padding(4)

            if !upload.caption.isEmpty {
                Text(upload.caption)
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.onPrimary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 9)
            }
        }
        .frame(width: cardWidth)
        .background(KlicColor.primary, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var fileCard: some View {
        let item = upload.items[0]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                progressRing(size: 26, tint: KlicColor.onPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName ?? "File")
                        .font(KlicFont.body())
                        .lineLimit(1)
                        .foregroundStyle(KlicColor.onPrimary)
                    Text(statusText(bytes: item.data.count))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.onPrimary.opacity(0.8))
                }
            }
            if !upload.caption.isEmpty {
                Text(upload.caption)
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.onPrimary)
            }
        }
        .padding(12)
        .frame(maxWidth: cardWidth, alignment: .leading)
        .background(KlicColor.primary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var progressOverlay: some View {
        if upload.failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            ZStack {
                progressRing(size: 44, tint: .white)
                Text("\(Int(upload.progress * 100))%")
                    .font(KlicFont.caption(11).weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func progressRing(size: CGFloat, tint: Color) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(upload.progress, 0.03))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.15), value: upload.progress)
    }

    private var failureActions: some View {
        HStack(spacing: 8) {
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(KlicFont.medium(13))
                    .foregroundStyle(KlicColor.onPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(KlicColor.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onDiscard) {
                Label("Discard", systemImage: "trash")
                    .font(KlicFont.medium(13))
                    .foregroundStyle(KlicColor.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(KlicColor.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var previewHeight: CGFloat {
        let item = upload.items.first(where: { $0.previewImage != nil })
        guard let w = item?.width, let h = item?.height, w > 0, h > 0 else { return 160 }
        return min(max((cardWidth - 8) * CGFloat(h) / CGFloat(w), 120), 300)
    }

    private func statusText(bytes: Int) -> String {
        if upload.failed { return "Upload failed" }
        let total = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(Int(upload.progress * 100))% of \(total)"
    }
}
