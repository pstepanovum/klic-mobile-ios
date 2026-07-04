import SwiftUI

/// §16.1: the quote CARD rendered at the top, INSIDE a reply's bubble — accent bar,
/// tinted card background, optional media thumbnail, sender title and one-line
/// snippet. Shared by every bubble kind (text, media card, voice/file pills,
/// big-emoji and video-note presentations) and by the pinned bar (§16.3).
struct ReplyCardView: View {
    let reply: ReplyPreview
    let authorName: String
    /// Hosted on the user's own accent-colored bubble → white-on-accent palette.
    var onPrimary: Bool = false
    var onTap: () -> Void = {}

    private var accent: Color { onPrimary ? KlicColor.onPrimary : KlicColor.primary }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3)

                if let stub = reply.attachment, stub.isVisual, reply.deleted != true {
                    ReplyThumbView(stub: stub)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(authorName)
                        .font(KlicFont.medium(14))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Text(snippet)
                        .font(KlicFont.caption(12))
                        .foregroundStyle(onPrimary ? KlicColor.onPrimary.opacity(0.85) : KlicColor.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    /// Parent text when it has any, else a localized media label (§16.1). The server
    /// fills `preview` with its own English kind label when the parent has no text —
    /// detect those and substitute the localized label.
    private var snippet: String {
        if reply.deleted == true { return String(localized: "Deleted message") }
        let preview = reply.preview
        if preview.isEmpty || Self.serverKindLabels.contains(preview) {
            return Self.mediaLabel(kind: reply.kind, attachment: reply.attachment)
        }
        return preview
    }

    /// The server's built-in kind labels (see the API's reply-preview shape) — when
    /// `preview` is one of these the parent had no text of its own.
    private static let serverKindLabels: Set<String> = [
        "📷 Photo", "🎤 Voice message", "🎥 Video", "🎥 Video message",
        "📎 File", "Sticker", "📞 Call", "Message", "Deleted message",
    ]

    /// True when `preview` is one of the server's built-in kind labels — the parent
    /// had no text, so clients substitute their own localized label (§16.1).
    static func isServerKindLabel(_ preview: String) -> Bool {
        serverKindLabels.contains(preview)
    }

    /// Localized label for a text-less parent (§16.1).
    static func mediaLabel(kind: String, attachment: ReplyAttachmentStub?) -> String {
        switch kind {
        case "IMAGE":
            if attachment?.contentType == "image/gif" { return String(localized: "GIF") }
            return String(localized: "Photo")
        case "VIDEO":      return String(localized: "Video")
        case "VIDEO_NOTE": return String(localized: "Video message")
        case "VOICE":      return String(localized: "Voice message")
        case "STICKER":    return String(localized: "Sticker")
        case "FILE":
            if let name = attachment?.fileName, !name.isEmpty { return name }
            return String(localized: "File")
        default:           return String(localized: "Message")
        }
    }
}

/// The quote card's media thumbnail: a ~38pt square (two text lines) with 4pt corner
/// radius — circular for round video messages (§16.1).
private struct ReplyThumbView: View {
    let stub: ReplyAttachmentStub

    @State private var image: UIImage?

    private var side: CGFloat { 38 }
    private var isRound: Bool { stub.kind == "VIDEO_NOTE" }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                KlicColor.textMuted.opacity(0.2)
                Image(systemName: stub.isVideoLike ? "video.fill" : "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .frame(width: side, height: side)
        .clipShape(isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
        .task(id: stub.url) {
            guard image == nil else { return }
            image = await Self.load(stub)
        }
    }

    /// Image parents load through the shared image cache (keyed by attachment id so
    /// presigned-URL rotation never re-downloads); video parents reuse the §14.2
    /// first-frame thumbnailer.
    private static func load(_ stub: ReplyAttachmentStub) async -> UIImage? {
        if stub.isVideoLike {
            return await VideoThumbnailer.thumbnail(for: stub.asAttachment)
        }
        guard let url = URL(string: stub.url) else { return nil }
        let cacheKey = stub.id.map { RemoteImageStore.attachmentCacheKey($0) }
        return await RemoteImageStore.shared.image(for: url, cacheKey: cacheKey)
    }
}

/// §16.1: sizes a bubble to `max(text width, quote card's natural width)` — the card
/// stretches to the bubble when the text is wider, and the bubble grows to fit the
/// card when the card is wider. A plain VStack can't express this (a
/// `maxWidth: .infinity` card would balloon the bubble to the full proposal).
///
/// Expects exactly two children: [0] the quote card (flexible width), [1] the content.
struct ReplyCardStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        let content = subviews[1].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        // The card's natural (hugging) width, capped by the proposal.
        let cardIdeal = subviews[0].sizeThatFits(.unspecified)
        let width = min(max(content.width, cardIdeal.width), maxWidth)
        let card = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: card.height + spacing + content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let card = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: card.height)
        )
        // The content wraps at the width it was measured against (the proposal),
        // mirroring TimeTuckLayout's contract.
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + card.height + spacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: proposal.width, height: nil)
        )
    }
}
