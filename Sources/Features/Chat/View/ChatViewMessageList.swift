import SwiftUI

/// True when the chat's bottom marker is within the viewport (used to hide the scroll-down button).
private struct AtBottomKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

extension ChatView {
    var messageList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        } else if hasMore {
                            Color.clear.frame(height: 1)
                                .onAppear { Task { await loadMore() } }
                        }
                        let items = visibleMessages
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, msg in
                            let isMine = msg.senderId == myId
                            let isFirst = idx == 0 || items[idx - 1].senderId != msg.senderId
                            let isLast  = idx == items.count - 1 || items[idx + 1].senderId != msg.senderId

                            if idx == 0 || !sameDay(items[idx - 1].createdAt, msg.createdAt) {
                                DateSeparator(dateString: msg.createdAt)
                            }

                            MessageBubble(
                                message: msg,
                                isMine: isMine,
                                isFirst: isFirst,
                                isLast: isLast,
                                isGroupChat: !isDirect,
                                senderName: senderDisplayName(for: msg.senderId),
                                senderAvatarURL: senderAvatarURL(for: msg.senderId),
                                replyAuthorName: msg.replyTo.map { replyAuthorName(for: $0.senderId) } ?? "",
                                mentionNames: mentionHighlightNames,
                                onCallBack: { kind in Task { await startCall(kind: kind) } },
                                onAvatarTap: isDirect ? nil : { openProfile(for: msg.senderId) },
                                onLongPress: { withAnimation(.easeIn(duration: 0.15)) { menuTarget = msg } },
                                onReactionTap: { emoji in Task { await react(msg, emoji: emoji) } },
                                onOpenAttachment: { attachment in
                                    selectedMediaAttachmentId = attachment.id
                                }
                            )
                            .id(msg.id)
                        }
                        // Optimistic sends: byte-progress pills below the delivered
                        // history until each is swapped for its server bubble (§9.1).
                        ForEach(outgoingUploads) { upload in
                            UploadingMessageBubble(
                                upload: upload,
                                onRetry: { retryUpload(upload.id) },
                                onDiscard: { discardUpload(upload.id) }
                            )
                            .id("upload-\(upload.id.uuidString)")
                        }
                        if peerIsTyping {
                            HStack { TypingDots(); Spacer(minLength: 56) }
                                .padding(.vertical, 1)
                                .id("typing-indicator")
                                .transition(.opacity)
                        }
                        // Bottom marker: reports whether it's within the viewport, so the
                        // scroll-down button reliably reflects the real scroll position.
                        Color.clear.frame(height: 1).id("bottom-sentinel")
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: AtBottomKey.self,
                                    value: g.frame(in: .named("chatScroll")).maxY <= outer.size.height + 60
                                )
                            })
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(.named("chatScroll"))
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                // Scrolling must NOT dismiss the keyboard; a single tap on the chat does.
                .scrollDismissesKeyboard(.never)
                .simultaneousGesture(TapGesture().onEnded { isComposerFocused = false })
                .onPreferenceChange(AtBottomKey.self) { atBottom = $0 }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        // Programmatic scroll keeps the keyboard open (unlike a user drag).
                        Button { scrollToBottom() } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(KlicColor.textPrimary)
                                .frame(width: 40, height: 40)
                                .background(KlicColor.surfaceRaised, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: atBottom)
                .onAppear { scrollProxy = proxy }
                .onChange(of: peerIsTyping) { _, typing in if typing { scrollToBottom() } }
                .onChange(of: visibleMessages.count) { _, _ in
                    if atBottom { scrollToBottom(animated: false) }
                }
            }
        }
    }

    private func sameDay(_ a: String, _ b: String) -> Bool {
        String(a.prefix(10)) == String(b.prefix(10))
    }

    func scrollToBottom(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { scrollProxy?.scrollTo("bottom-sentinel", anchor: .bottom) }
        } else {
            scrollProxy?.scrollTo("bottom-sentinel", anchor: .bottom)
        }
    }
}
