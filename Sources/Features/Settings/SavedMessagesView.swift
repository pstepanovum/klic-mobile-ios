import SwiftUI
import Inject

/// Settings → Saved messages (§14.4): everything the user starred, across every
/// conversation (GET /me/starred), rendered like a message list — sender,
/// conversation context line, timestamp, media previews. Tapping an entry opens the
/// conversation; long-press unstars.
struct SavedMessagesView: View {
    @ObserveInjection var inject

    @ObservedObject private var store = ConversationStore.shared
    @State private var items: [StarredMessageItem] = []
    @State private var nextCursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var unavailable = false
    @State private var openedConversation: Conversation?
    /// Long-press target for the unstar sheet.
    @State private var unstarTarget: Message?

    private var myId: String? { AccessToken.subject(of: TokenStore.accessToken) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    SavedMessageRow(
                        message: item.message,
                        senderName: senderName(item),
                        contextLine: contextLine(item)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { open(item.message) }
                    .onLongPressGesture(minimumDuration: 0.3) { unstarTarget = item.message }
                    .onAppear {
                        if item.id == items.last?.id, nextCursor != nil {
                            Task { await loadMore() }
                        }
                    }
                }
                if loading {
                    ProgressView().padding(.vertical, 14)
                }
            }
            .padding(16)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .overlay {
            if loaded, items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(KlicColor.textMuted)
                    Text(unavailable
                         ? "Saved messages need the latest server."
                         : "No saved messages yet.\nLong-press a message and tap Star.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("Saved messages")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedConversation) { conversation in
            ChatView(conversation: conversation)
        }
        .klicSelectionSheet(
            isPresented: Binding(
                get: { unstarTarget != nil },
                set: { if !$0 { unstarTarget = nil } }
            ),
            title: String(localized: "Remove from saved messages?"),
            options: [KlicSheetOption(id: "unstar", label: String(localized: "Unstar"), isDestructive: true)]
        ) { _ in
            guard let message = unstarTarget else { return }
            unstarTarget = nil
            Task { await unstar(message) }
        }
        .task {
            if store.conversations.isEmpty { await store.refresh() }
            if !loaded { await loadMore() }
        }
        .enableInjection()
    }

    // MARK: Data

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await APIClient.shared.starredMessages(cursor: nextCursor) else {
            unavailable = items.isEmpty
            loaded = true
            nextCursor = nil
            return
        }
        loaded = true
        items += page.items.filter { item in !items.contains(where: { $0.id == item.id }) }
        nextCursor = page.nextCursor
    }

    private func unstar(_ message: Message) async {
        items.removeAll { $0.id == message.id }
        ChatCaches.starred[message.conversationId]?.removeAll { $0.id == message.id }
        try? await APIClient.shared.unstarMessage(id: message.id)
    }

    private func open(_ message: Message) {
        if let conversation = store.conversations.first(where: { $0.id == message.conversationId }) {
            openedConversation = conversation
            return
        }
        Task {
            await store.refresh()
            if let conversation = store.conversations.first(where: { $0.id == message.conversationId }) {
                openedConversation = conversation
            }
        }
    }

    // MARK: Context resolution

    /// Sender + conversation come from the server's §14.4 enrichment; the local
    /// conversations cache is only a fallback for older servers.
    private func conversation(_ message: Message) -> Conversation? {
        store.conversations.first { $0.id == message.conversationId }
    }

    private func senderName(_ item: StarredMessageItem) -> String {
        if item.message.senderId == myId { return String(localized: "You") }
        if let sender = item.sender { return sender.displayName }
        guard let convo = conversation(item.message) else { return String(localized: "User") }
        return convo.members.first(where: { $0.id == item.message.senderId })?.displayName
            ?? String(localized: "User")
    }

    /// "in <chat>" line under the sender, mirroring the chat list naming.
    private func contextLine(_ item: StarredMessageItem) -> String {
        if let context = item.conversation {
            guard let title = context.title, !title.isEmpty else { return "" }
            return context.type == "DIRECT"
                ? String(localized: "in chat with \(title)")
                : String(localized: "in \(title)")
        }
        guard let convo = conversation(item.message) else { return "" }
        if let title = convo.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return String(localized: "in \(title)")
        }
        if convo.type == "DIRECT", let peer = convo.members.first {
            return String(localized: "in chat with \(peer.displayName)")
        }
        let names = convo.members.map(\.displayName).joined(separator: ", ")
        return names.isEmpty ? "" : String(localized: "in \(names)")
    }
}

// MARK: - Row

private struct SavedMessageRow: View {
    let message: Message
    let senderName: String
    let contextLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderName)
                        .font(KlicFont.medium(14))
                        .foregroundStyle(KlicColor.primary)
                    if !contextLine.isEmpty {
                        Text(contextLine)
                            .font(KlicFont.caption(11))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(Self.stamp(message.createdAt))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }

            mediaPreview

            if !message.body.isEmpty {
                Text(message.body)
                    .font(KlicFont.body(15))
                    .foregroundStyle(KlicColor.textPrimary)
                    .lineLimit(4)
            } else if message.attachments.isEmpty, let fallback = fallbackText {
                Text(fallback)
                    .font(KlicFont.body(15))
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Media previews render properly (§14.4): image/video thumbnails, voice and
    /// file rows with their metadata.
    @ViewBuilder private var mediaPreview: some View {
        let media = message.attachments.filter { $0.isImage || $0.isVideo }
        let voice = message.attachments.first { $0.isVoice }
        let files = message.attachments.filter { $0.isFile }

        if !media.isEmpty {
            HStack(spacing: 4) {
                ForEach(media.prefix(3)) { attachment in
                    mediaThumb(attachment)
                }
                if media.count > 3 {
                    Text("+\(media.count - 3)")
                        .font(KlicFont.caption(12).weight(.semibold))
                        .foregroundStyle(KlicColor.textMuted)
                        .frame(width: 36, height: 72)
                }
            }
        }
        if let voice {
            attachmentLine(icon: "mic.fill", text: voiceLabel(voice))
        }
        ForEach(files) { file in
            attachmentLine(icon: "doc.fill", text: file.fileName ?? String(localized: "File"))
        }
    }

    private func mediaThumb(_ attachment: Attachment) -> some View {
        Group {
            if attachment.isVideo {
                VideoThumbnailView(attachment: attachment, glyphSize: 20)
            } else if let url = URL(string: attachment.url) {
                RemoteImage(url: url, cacheKey: RemoteImageStore.attachmentCacheKey(attachment.id)) { phase in
                    switch phase {
                    case .success(let image):
                        GeometryReader { geo in
                            image.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                    case .failure:
                        KlicColor.surfaceRaised.overlay(
                            Image(systemName: "photo").foregroundStyle(KlicColor.textMuted)
                        )
                    default:
                        KlicColor.surfaceRaised.overlay(LoadingCircle())
                    }
                }
            } else {
                KlicColor.surfaceRaised
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func attachmentLine(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(KlicColor.primary)
            Text(text)
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textPrimary)
                .lineLimit(1)
        }
    }

    private var fallbackText: String? {
        if message.isSticker { return String(localized: "Sticker") }
        if message.isCallEvent { return message.call?.isVideo == true ? String(localized: "Video call") : String(localized: "Voice call") }
        return nil
    }

    private func voiceLabel(_ attachment: Attachment) -> String {
        let seconds = (attachment.durationMs ?? 0) / 1000
        let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(localized: "Voice message · \(duration)")
    }

    private static func stamp(_ iso: String) -> String {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
