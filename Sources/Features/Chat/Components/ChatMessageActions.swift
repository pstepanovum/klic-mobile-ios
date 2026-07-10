import SwiftUI

// Quick-reaction palette shown on the long-press menu.
let quickReactions = ["❤️", "👍", "👎", "😂", "😮", "😢", "🔥"]

// MARK: - Long-press actions overlay

/// A dimmed full-screen menu shown when a bubble is long-pressed: a reaction bar on
/// top, a compact preview of the message, and the action list below.
struct MessageActionsOverlay: View {
    @ObservedObject var chatTheme = ChatThemeStore.shared
    let message: Message
    let isMine: Bool
    let peerName: String
    /// §16.4: own text/caption messages within the 48h window.
    var canEdit: Bool = false
    /// §16.3: DIRECT → either participant; GROUP → admin only.
    var canPin: Bool = false
    /// §16.3: already pinned → the row reads "Unpin".
    var pinned: Bool = false
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    var onToggleStar: () -> Void = {}
    var onEdit: () -> Void = {}
    var onPin: () -> Void = {}
    /// §12.1 "Hide" — device-local content filter, other people's messages only.
    var onHide: () -> Void = {}
    /// §12.1 "Report message" — shown for other people's messages only.
    var onReport: () -> Void = {}
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private var mineEmojis: Set<String> { Set(message.reactions.filter { $0.mine }.map { $0.emoji }) }
    private var hasBody: Bool { !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// §19.4: the message's images — a multi-image message gets a paged preview so the
    /// user can swipe through them without leaving the action sheet.
    private var previewImages: [Attachment] { message.attachments.filter { $0.isImage } }
    private var isMultiImage: Bool { previewImages.count > 1 }

    /// §19.4: which image the paged preview is showing.
    @State private var previewPage = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: isMine ? .trailing : .leading, spacing: 12) {
                reactionBar
                if isMultiImage {
                    mediaPreviewPager
                } else {
                    previewBubble
                }
                actionsCard
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 420)
        }
    }

    /// §19.4: a mini paged media viewer embedded in the preview. Swiping LEFT/RIGHT
    /// pages through the message's images (paged, with a dot indicator) without
    /// dismissing the sheet — the reaction bar and action list stay live above/below.
    private var mediaPreviewPager: some View {
        let side: CGFloat = 264
        return VStack(spacing: 10) {
            TabView(selection: $previewPage) {
                ForEach(Array(previewImages.enumerated()), id: \.element.id) { index, attachment in
                    RemoteImage(
                        url: URL(string: attachment.url),
                        cacheKey: RemoteImageStore.attachmentCacheKey(attachment.id)
                    ) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            KlicColor.surfaceRaised
                                .overlay(Image(systemName: "photo").foregroundStyle(KlicColor.textMuted))
                        default:
                            KlicColor.surfaceRaised.overlay(LoadingCircle())
                        }
                    }
                    .frame(width: side, height: side)
                    .clipped()
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            // Dot indicator — current page highlighted.
            HStack(spacing: 6) {
                ForEach(previewImages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == previewPage ? KlicColor.textPrimary : KlicColor.textMuted.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)
    }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 27))
                        .frame(width: 40, height: 40)
                        .background(mineEmojis.contains(emoji) ? KlicColor.primary.opacity(0.25) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KlicColor.surface, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    @ViewBuilder private var previewBubble: some View {
        Text(previewText)
            .font(KlicFont.body())
            .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
            .lineLimit(6)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMine ? chatTheme.bubbleColor(for: message.conversationId) : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)
    }

    private var previewText: String {
        if hasBody { return message.body }
        if message.isSticker { return "Sticker" }
        if let a = message.attachments.first {
            switch a.kind {
            case "IMAGE":      return "📷 Photo"
            case "VOICE":      return "🎤 Voice message"
            case "VIDEO":      return "🎥 Video"
            case "VIDEO_NOTE": return "🎥 Video message"
            default:           return "📎 File"
            }
        }
        return "Message"
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            ActionRow(title: String(localized: "Reply"), systemImage: "arrowshape.turn.up.left") { onReply(); onDismiss() }
            if hasBody {
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(title: String(localized: "Copy"), systemImage: "doc.on.doc") { onCopy(); onDismiss() }
            }
            if canEdit {
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(title: String(localized: "Edit"), systemImage: "pencil") { onEdit(); onDismiss() }
            }
            if canPin {
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(
                    title: pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    systemImage: pinned ? "pin.slash" : "pin"
                ) { onPin() }
            }
            Divider().overlay(KlicColor.surfaceRaised)
            ActionRow(
                title: message.starred == true ? "Unstar" : "Star",
                systemImage: message.starred == true ? "star.slash" : "star"
            ) { onToggleStar(); onDismiss() }
            if !isMine {
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(title: String(localized: "Hide"), systemImage: "eye.slash") {
                    onHide()
                }
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(title: String(localized: "Report message"), systemImage: "exclamationmark.bubble") {
                    onReport()
                }
            }
            Divider().overlay(KlicColor.surfaceRaised)
            ActionRow(title: String(localized: "Delete"), systemImage: "trash", destructive: true) { onDelete() }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 260)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(KlicFont.body(15))
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 16))
            }
            .foregroundStyle(destructive ? KlicColor.danger : KlicColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reactions INSIDE the bubble (§14.5)

/// Small reaction chips rendered at a bubble's bottom edge, INSIDE its background.
/// The chip fill is a subtle contrast against whichever surface hosts it: the user's
/// own accent-colored bubble, the neutral peer bubble, or a media edge (scrim-backed).
/// The user's own reaction gets a slightly stronger chip. Tap behavior unchanged.
struct InlineReactionChips: View {
    let reactions: [Reaction]
    /// Hosted on the user's own accent-colored bubble.
    var onPrimary: Bool = false
    /// Hosted on a media edge (photo/bento/video) — scrim-backed chips.
    var onMedia: Bool = false
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { reaction in
                Button { onTap(reaction.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji).font(.system(size: 12))
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(KlicFont.caption(10).weight(.semibold))
                                .foregroundStyle(countColor)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(fill(reaction), in: Capsule())
                    .overlay {
                        if reaction.mine {
                            Capsule().strokeBorder(stroke, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fill(_ reaction: Reaction) -> Color {
        if onMedia { return .black.opacity(reaction.mine ? 0.62 : 0.45) }
        if onPrimary { return .white.opacity(reaction.mine ? 0.38 : 0.22) }
        return reaction.mine ? KlicColor.primary.opacity(0.16) : KlicColor.textPrimary.opacity(0.08)
    }

    private var stroke: Color {
        if onMedia { return .white.opacity(0.85) }
        if onPrimary { return .white.opacity(0.9) }
        return KlicColor.primary.opacity(0.75)
    }

    private var countColor: Color {
        if onMedia { return .white }
        if onPrimary { return KlicColor.onPrimary }
        return KlicColor.textPrimary.opacity(0.75)
    }
}

// MARK: - Reaction pills (under a bubble-less message)

struct ReactionPills: View {
    let reactions: [Reaction]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(reactions, id: \.emoji) { r in
                Button { onTap(r.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 13))
                        if r.count > 1 {
                            Text("\(r.count)")
                                .font(KlicFont.caption(11))
                                .foregroundStyle(r.mine ? KlicColor.onPrimary : KlicColor.textMuted)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(r.mine ? KlicColor.primary : KlicColor.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// The quote card at the top of reply bubbles lives in ReplyCardView.swift (§16.1);
// the composer's "replying to …" banner lives inside MessageComposer (§15.1).

// MARK: - Tombstone

/// Placeholder shown in place of a message that was deleted for everyone.
struct DeletedBubble: View {
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 56) }
            HStack(spacing: 6) {
                Image(systemName: "nosign").font(.system(size: 12))
                Text("This message was deleted").font(KlicFont.body(14)).italic()
            }
            .foregroundStyle(KlicColor.textMuted)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
            if !isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Typing indicator

/// Three dots that pulse in sequence — shown while the peer is typing.
struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(KlicColor.textMuted)
                    .frame(width: 7, height: 7)
                    .opacity(opacity(for: i))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }

    private func opacity(for index: Int) -> Double {
        let base = 0.3 + 0.7 * abs(sin((phase * .pi) + Double(index) * 0.6))
        return min(1, base)
    }
}
