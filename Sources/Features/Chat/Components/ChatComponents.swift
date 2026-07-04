import SwiftUI
import UIKit

// MARK: - Message bubble

struct MessageBubble: View {
    // §12.3: own bubbles take the user's chosen accent color. Not private — a
    // private stored property would make the memberwise init private too.
    @ObservedObject var chatTheme = ChatThemeStore.shared
    let message: Message
    let isMine: Bool
    let isFirst: Bool
    let isLast: Bool
    var isGroupChat: Bool = false
    var senderName: String? = nil
    var senderAvatarURL: String? = nil
    var replyAuthorName: String = ""
    /// Member names highlighted as mentions alongside @all (group chats, §9.5).
    var mentionNames: [String] = []
    var onCallBack: (String) -> Void = { _ in }
    var onAvatarTap: (() -> Void)? = nil
    var onLongPress: () -> Void = {}
    var onReactionTap: (String) -> Void = { _ in }
    var onOpenAttachment: (Attachment) -> Void = { _ in }

    private var topRadius:    CGFloat { isFirst ? 18 : (isMine ? 18 : 4) }
    private var bottomRadius: CGFloat { isLast  ? 18 : (isMine ? 4  : 18) }
    private var tailRadius:   CGFloat { isLast  ? 4  : 18 }

    /// §11.6: with read receipts OFF, DMs never show the blue read tick (both ways —
    /// the server also stops emitting/exposing read state); groups are unaffected.
    private var displayStatus: String? {
        guard let status = message.status else { return nil }
        if status == "read", !isGroupChat, !PrivacyPrefs.readReceipts { return "delivered" }
        return status
    }

    var body: some View {
        if message.isDeleted {
            DeletedBubble(isMine: isMine)
        } else if message.isSystem {
            systemBubble
        } else if message.isCallEvent, let call = message.call {
            CallEventRow(call: call, outgoing: isMine, time: shortTime(message.createdAt), onCallBack: onCallBack)
        } else if message.isSticker, let stickerId = message.stickerId {
            stickerBubble(stickerId)
        } else {
            standardBubble
        }
    }

    private var systemBubble: some View {
        Text(message.body)
            .font(KlicFont.caption(12))
            .foregroundStyle(KlicColor.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(KlicColor.surfaceRaised, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func stickerBubble(_ stickerId: String) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            StickerMessageView(stickerId: stickerId, isMine: isMine, time: shortTime(message.createdAt))
                .onLongPressGesture(minimumDuration: 0.3, perform: onLongPress)
            if !message.reactions.isEmpty {
                ReactionPills(reactions: message.reactions, onTap: onReactionTap)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    /// §13.3: the gutter reserved opposite a bubble. Small enough that text pills can
    /// fill ~85% of the row before wrapping (was 56 — bubbles wrapped too early).
    private static let bubbleGutter: CGFloat = 44

    private var standardBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: Self.bubbleGutter) }

            if showGroupAvatar {
                groupAvatar
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                messageContent

                if !message.reactions.isEmpty {
                    ReactionPills(reactions: message.reactions, onTap: onReactionTap)
                }
            }
            .onLongPressGesture(minimumDuration: 0.3, perform: onLongPress)

            if showGroupAvatarSpacer {
                Color.clear.frame(width: 34, height: 34)
            }

            if !isMine { Spacer(minLength: Self.bubbleGutter) }
        }
        .padding(.vertical, 1)
    }

    /// IMAGE/VIDEO attachments render as one unified card (bento grid + caption inside),
    /// so the plain text bubble is skipped for them — the caption lives in the card.
    private var hasMediaAttachments: Bool {
        message.attachments.contains { $0.isImage || $0.isVideo }
    }

    private var messageContent: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            if !message.attachments.isEmpty {
                if let reply = message.replyTo {
                    ReplyQuoteView(reply: reply, authorName: replyAuthorName)
                }
                if showSenderName, hasMediaAttachments, let senderName {
                    Text(senderName)
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.primary.opacity(0.95))
                }
                MessageAttachmentsView(
                    attachments: message.attachments,
                    isMine: isMine,
                    caption: hasMediaAttachments ? message.body : "",
                    showTime: message.body.isEmpty,
                    time: shortTime(message.createdAt),
                    status: displayStatus,
                    starred: message.starred == true,
                    highlightMentions: isGroupChat,
                    mentionNames: mentionNames,
                    conversationId: message.conversationId,
                    onOpenAttachment: onOpenAttachment,
                    onLongPress: onLongPress
                )
            }

            if !message.body.isEmpty && !hasMediaAttachments {
                VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                    if showSenderName, let senderName {
                        Text(senderName)
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.primary.opacity(0.95))
                    }

                    if let emojiCount = emojiOnlyCount {
                        // §10.3: 1–3 emoji-only messages render WhatsApp-style — no
                        // bubble background, large glyphs (1 biggest, 2–3 smaller).
                        // §13.7: time/ticks sit BELOW the emoji, bottom-trailing.
                        if let reply = message.replyTo, message.attachments.isEmpty {
                            ReplyQuoteView(reply: reply, authorName: replyAuthorName)
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(message.body.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: Self.bigEmojiSize(emojiCount)))
                            inlineTimeStatus(onPrimary: false)
                        }
                    } else if isBareLink, let url = detectedURL {
                        // A message that's only a link — show the rich card alone, no chat bubble,
                        // matching how Messages presents standalone URLs.
                        LinkPreviewCard(url: url)
                            .frame(maxWidth: 260)
                        inlineTimeStatus(onPrimary: false)
                    } else {
                        if let reply = message.replyTo, message.attachments.isEmpty {
                            ReplyQuoteView(reply: reply, authorName: replyAuthorName, onPrimary: isMine)
                        }
                        HStack(alignment: .bottom, spacing: 6) {
                            RichMessageText(
                                text: message.body,
                                font: UIFont(name: "TikTokSans-Regular", size: 16) ?? .systemFont(ofSize: 16),
                                textColor: UIColor(isMine ? KlicColor.onPrimary : KlicColor.textPrimary),
                                highlightMentions: isGroupChat,
                                mentionNames: mentionNames,
                                mentionColor: UIColor(isMine ? KlicColor.onPrimary : KlicColor.primary),
                                onLongPress: onLongPress
                            )
                            inlineTimeStatus(onPrimary: isMine)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            isMine ? chatTheme.bubbleColor : KlicColor.surfaceRaised,
                            in: UnevenRoundedRectangle(
                                topLeadingRadius:     isMine ? 18 : topRadius,
                                bottomLeadingRadius:  isMine ? 18 : bottomRadius,
                                bottomTrailingRadius: isMine ? tailRadius : 18,
                                topTrailingRadius:    isMine ? topRadius : 18
                            )
                        )

                        if let url = detectedURL {
                            LinkPreviewCard(url: url)
                                .frame(maxWidth: 260)
                        }
                    }
                }
            }
        }
    }

    private var showSenderName: Bool {
        isGroupChat && !isMine && isFirst
    }

    private var showGroupAvatar: Bool {
        isGroupChat && !isMine && isLast
    }

    private var showGroupAvatarSpacer: Bool {
        isGroupChat && !isMine && !isLast
    }

    @ViewBuilder
    private var groupAvatar: some View {
        if let onAvatarTap {
            Button(action: onAvatarTap) {
                AvatarView(url: senderAvatarURL, name: senderName ?? "User", size: 34)
            }
            .buttonStyle(.plain)
        } else {
            AvatarView(url: senderAvatarURL, name: senderName ?? "User", size: 34)
        }
    }

    @ViewBuilder
    private func inlineTimeStatus(onPrimary: Bool) -> some View {
        HStack(spacing: 3) {
            if message.starred == true {
                StarIndicator(onPrimary: onPrimary)
            }
            Text(shortTime(message.createdAt))
                .font(KlicFont.caption(11))
                .foregroundStyle(onPrimary ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
            if isMine, let status = displayStatus {
                MessageTicks(status: status, onPrimary: onPrimary)
            }
        }
    }

    /// §10.3: the number of grapheme clusters when the body is 1–3 emoji and nothing
    /// else. Swift's `Character` counts ZWJ sequences and skin tones as one cluster.
    private var emojiOnlyCount: Int? {
        let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return nil }
        for character in trimmed where !character.isEmojiCluster { return nil }
        return trimmed.count
    }

    private static func bigEmojiSize(_ count: Int) -> CGFloat {
        switch count {
        case 1: return 68
        case 2: return 54
        default: return 46
        }
    }

    private var detectedURL: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let text = message.body
        let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        return match?.url
    }

    private var isBareLink: Bool {
        guard let url = detectedURL else { return false }
        return message.body.trimmingCharacters(in: .whitespacesAndNewlines) == url.absoluteString
    }

    private func shortTime(_ iso: String) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let df2 = ISO8601DateFormatter()
        df2.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: iso) ?? df2.date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

private extension Character {
    /// True for emoji grapheme clusters, including ZWJ sequences, flags, keycaps and
    /// skin-tone modifiers (§10.3). Plain digits/symbols with a text presentation
    /// default (e.g. "1", "#") don't count unless combined into an emoji cluster.
    var isEmojiCluster: Bool {
        guard let first = unicodeScalars.first else { return false }
        if unicodeScalars.count > 1 {
            return first.properties.isEmoji
        }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && first.value > 0x238C)
    }
}

// MARK: - Date separator

struct DateSeparator: View {
    let dateString: String

    var body: some View {
        Text(label)
            .font(KlicFont.caption(12))
            .foregroundStyle(KlicColor.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(KlicColor.surfaceRaised, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var label: String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let df2 = ISO8601DateFormatter()
        df2.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: dateString) ?? df2.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date)     { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }
}
