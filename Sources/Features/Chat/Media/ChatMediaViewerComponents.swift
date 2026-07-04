import SwiftUI

struct MediaViewerTopBar: View {
    let senderName: String
    let timestamp: String
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(senderName)
                    .font(KlicFont.headline(16))
                    .foregroundStyle(.white)
                Text(timestamp)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            HStack(spacing: 10) {
                Button(action: {}) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                Button(action: {}) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.black.opacity(0.55))
    }
}

struct MediaViewerVideoControls: View {
    @Binding var currentTime: Double
    let duration: Double
    @Binding var playbackRate: Float
    let onSeek: (Double) -> Void
    let onRateChange: (Float) -> Void
    let onPictureInPicture: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(formatDuration(currentTime))
                    .font(KlicFont.caption(12))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { duration > 0 ? currentTime : 0 },
                        set: { newValue in onSeek(newValue) }
                    ),
                    in: 0...max(duration, 0.1)
                )
                .tint(.white)

                Text(formatDuration(duration))
                    .font(KlicFont.caption(12))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
            }

            HStack {
                HStack(spacing: 10) {
                    speedButton(1.0, title: String(localized: "1x"))
                    speedButton(1.5, title: String(localized: "1.5x"))
                    speedButton(2.0, title: String(localized: "2x"))
                }
                Spacer()
                Button(action: onPictureInPicture) {
                    Image(systemName: "pip")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45))
    }

    private func speedButton(_ rate: Float, title: String) -> some View {
        Button {
            playbackRate = rate
            onRateChange(rate)
        } label: {
            Text(title)
                .font(KlicFont.caption(12))
                .foregroundStyle(playbackRate == rate ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(playbackRate == rate ? Color.white : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MediaViewerBottomPanel: View {
    let item: ChatMediaGalleryItem
    let items: [ChatMediaGalleryItem]
    let currentAttachmentId: String
    let isPlaying: Bool
    var preparingShare: Bool = false
    let onReact: (String, String) -> Void
    let onSelectItem: (String) -> Void
    let onShare: () -> Void
    var onForward: () -> Void = {}
    var onToggleStar: () -> Void = {}
    var onReply: () -> Void = {}
    let onPlayPause: () -> Void
    let onDelete: () -> Void

    @State private var showReactionRow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !item.caption.isEmpty {
                Text(item.caption)
                    .font(KlicFont.body(15))
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }

            // Inline quick-reaction row (same pattern as the chat's long-press overlay) —
            // no native Menu (§9.2).
            if showReactionRow {
                HStack(spacing: 6) {
                    ForEach(quickReactions, id: \.self) { emoji in
                        Button {
                            onReact(item.messageId, emoji)
                            withAnimation(.easeOut(duration: 0.15)) { showReactionRow = false }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .background(.white.opacity(0.12), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showReactionRow = true }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "face.smiling")
                        Text(reactionSummary(item.reactions))
                    }
                    .font(KlicFont.caption(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            MediaViewerThumbnailStrip(
                items: items,
                currentAttachmentId: currentAttachmentId,
                onSelectItem: onSelectItem
            )

            HStack {
                actionButton(
                    preparingShare ? "hourglass" : "square.and.arrow.up",
                    title: String(localized: "Share"), action: onShare
                )
                actionButton("arrowshape.turn.up.right", title: String(localized: "Forward"), action: onForward)
                // Play/pause only exists for videos — images NEVER get a Play action (§10.9).
                if item.isVideo {
                    actionButton(
                        isPlaying ? "pause.fill" : "play.fill",
                        title: isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                        action: onPlayPause
                    )
                }
                actionButton(
                    item.starred ? "star.fill" : "star",
                    title: item.starred ? String(localized: "Starred") : String(localized: "Star"),
                    highlighted: item.starred,
                    action: onToggleStar
                )
                actionButton("arrowshape.turn.up.left", title: String(localized: "Reply"), action: onReply)
                actionButton("trash", title: String(localized: "Delete"), destructive: true, action: onDelete)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(.black.opacity(0.62))
    }

    private func reactionSummary(_ reactions: [Reaction]) -> String {
        guard !reactions.isEmpty else { return "React" }
        return reactions.map(\.emoji).joined(separator: " ")
    }

    private func actionButton(
        _ icon: String, title: String, destructive: Bool = false,
        highlighted: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(KlicFont.caption(11))
            }
            .foregroundStyle(destructive ? KlicColor.danger : (highlighted ? Color.yellow : .white))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct MediaViewerThumbnailStrip: View {
    let items: [ChatMediaGalleryItem]
    let currentAttachmentId: String
    let onSelectItem: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        onSelectItem(item.attachmentId)
                    } label: {
                        ZStack {
                            if item.isVideo, let attachment = item.attachment {
                                // §14.2: first-frame thumbnail in the viewer strip too.
                                VideoThumbnailView(attachment: attachment, showsGlyph: false)
                            } else if let thumbnailURL = URL(string: item.thumbnailURL ?? item.url) {
                                RemoteImage(url: thumbnailURL, cacheKey: RemoteImageStore.attachmentCacheKey(item.attachmentId)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    case .failure:
                                        Color.white.opacity(0.1)
                                    default:
                                        Color.white.opacity(0.08)
                                    }
                                }
                            } else {
                                Color.white.opacity(0.08)
                            }

                            if item.isVideo {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                        }
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(currentAttachmentId == item.attachmentId ? Color.white : .clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
