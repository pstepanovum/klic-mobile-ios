import SwiftUI

/// §16.3: the pinned-messages bar at the top of a chat (below the header) — a
/// "Pinned Message" title + snippet of the current pin, a thumbnail when the pin
/// has visual media, and a vertical segmented indicator when multiple pins exist
/// (capped at 3 visible segments). TAP → jump to that pin (the chat steps the
/// cursor to the previous pin for the next tap, cycling); × → unpin/hide.
struct PinnedMessageBar: View {
    /// All pins, oldest→newest.
    let pins: [ReplyPreview]
    /// Index of the pin the bar currently shows / jumps to.
    let cursor: Int
    let onTap: () -> Void
    let onClose: () -> Void

    private var current: ReplyPreview? {
        guard pins.indices.contains(cursor) else { return pins.last }
        return pins[cursor]
    }

    var body: some View {
        if let pin = current {
            HStack(spacing: 10) {
                segmentIndicator

                if let stub = pin.attachment, stub.isVisual, pin.deleted != true {
                    PinnedThumb(stub: stub)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Pinned Message")
                        .font(KlicFont.medium(13))
                        .foregroundStyle(KlicColor.primary)
                        .lineLimit(1)
                    Text(snippet(pin))
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(KlicColor.background.opacity(0.97))
            .overlay(alignment: .bottom) {
                Divider().opacity(0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }

    /// Vertical segments on the leading edge — one per pin (≤3 visible; more pins
    /// collapse into the 3-segment cap), the current pin's segment highlighted.
    @ViewBuilder private var segmentIndicator: some View {
        if pins.count <= 1 {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(KlicColor.primary)
                .frame(width: 3, height: 32)
        } else {
            let visible = min(pins.count, 3)
            let active = activeSegment(visible: visible)
            VStack(spacing: 2) {
                ForEach(0..<visible, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index == active ? KlicColor.primary : KlicColor.primary.opacity(0.3))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 3, height: 32)
        }
    }

    private func activeSegment(visible: Int) -> Int {
        guard pins.count > 1 else { return 0 }
        // Map the cursor onto the capped segment strip (newest at the bottom).
        let fraction = Double(cursor) / Double(pins.count - 1)
        return min(visible - 1, Int(round(fraction * Double(visible - 1))))
    }

    private func snippet(_ pin: ReplyPreview) -> String {
        if pin.deleted == true { return String(localized: "Deleted message") }
        if pin.preview.isEmpty || ReplyCardView.isServerKindLabel(pin.preview) {
            return ReplyCardView.mediaLabel(kind: pin.kind, attachment: pin.attachment)
        }
        return pin.preview
    }
}

/// Small thumbnail on the pinned bar (media-label rules from §16.1) — square,
/// circular for round video messages.
private struct PinnedThumb: View {
    let stub: ReplyAttachmentStub

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                KlicColor.textMuted.opacity(0.2)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(stub.kind == "VIDEO_NOTE" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
        .task(id: stub.url) {
            guard image == nil else { return }
            if stub.isVideoLike {
                image = await VideoThumbnailer.thumbnail(for: stub.asAttachment)
            } else if let url = URL(string: stub.url) {
                let key = stub.id.map { RemoteImageStore.attachmentCacheKey($0) }
                image = await RemoteImageStore.shared.image(for: url, cacheKey: key)
            }
        }
    }
}
