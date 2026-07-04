import SwiftUI

/// A reply target rendered INSIDE the composer's input container (§15.1).
struct ComposerReplyPreview: Equatable {
    let authorName: String
    let preview: String
}

/// The chat input row: attach (+), text pill with inline sticker button, and a send/mic
/// button. The row itself has no background — the controls float on the chat; only the
/// individual controls (pill, buttons) carry their own fill.
struct MessageComposer: View {
    // §12.3: the send/record buttons follow the chat theme's bubble accent
    // (§14.3: resolved per conversation — group > per-chat > global).
    @ObservedObject var chatTheme = ChatThemeStore.shared
    var conversationId: String? = nil

    enum CaptureMode {
        case audio
        case video
    }

    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @ObservedObject var recorder: AudioRecorder
    let uploading: Bool
    let hasPendingAttachments: Bool
    @Binding var captureMode: CaptureMode
    /// §15.1: when replying, the quoted preview lives inside the input container —
    /// one rounded shape with the banner on top and the text field below.
    var replyPreview: ComposerReplyPreview? = nil
    var onCancelReply: () -> Void = {}
    let onAttach: () -> Void
    let onStickers: () -> Void
    let onSend: () -> Void
    let onToggleCaptureMode: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onCancelRecording: () -> Void
    let onSendVoice: () -> Void

    /// §15.1: measured height of the input container — drives the dynamic radius.
    @State private var inputHeight: CGFloat = 0

    var body: some View {
        Group {
            if recorder.isRecording {
                recordingBar
            } else {
                normalComposer
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
    }

    /// §15.1: full capsule while the input is one line tall, then the radius
    /// CONTINUOUSLY flattens as the container grows (multi-line text, reply banner)
    /// down to a ~17pt floor — mirroring the §14.6 bubble interpolation.
    private var inputRadius: CGFloat {
        let height = inputHeight
        guard height > 0 else { return 23 }
        let capsule = min(height / 2, 23)
        guard height > 52 else { return capsule }
        return max(17, capsule - (height - 52) * 0.09)
    }

    // Bottom-aligned so the +, emoji, and send controls stay pinned to the BOTTOM
    // of the input as it grows (§15.1) — never floating at its vertical center.
    private var normalComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(width: 44, height: 44)
                    .background(KlicColor.surfaceRaised, in: Circle())
            }
            .disabled(uploading)

            // One rounded input container: optional reply banner on top (§15.1),
            // text row with the emoji/sticker button tucked inside below.
            VStack(spacing: 0) {
                if let reply = replyPreview {
                    replyBanner(reply)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .tint(KlicColor.primary)
                        .focused(focused)
                    Button { focused.wrappedValue = false; onStickers() } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .disabled(uploading)
                    .padding(.bottom, 1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            // Capsule at 1 line (matching the Login-page inputs, §9.8), flattening
            // continuously toward 17pt as the container grows (§15.1).
            .background(
                KlicColor.surfaceRaised,
                in: RoundedRectangle(cornerRadius: inputRadius, style: .continuous)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ComposerInputHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ComposerInputHeightKey.self) { inputHeight = $0 }

            let canSend = hasPendingAttachments || !draft.trimmingCharacters(in: .whitespaces).isEmpty
            composerActionButton(canSend: canSend)
        }
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: replyPreview)
    }

    private func replyBanner(_ reply: ComposerReplyPreview) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(KlicColor.primary)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to \(reply.authorName)")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.primary)
                Text(reply.preview)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onCancelReply) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func composerActionButton(canSend: Bool) -> some View {
        if canSend {
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            }
            .disabled(uploading)
        } else {
            CaptureRecordButton(
                conversationId: conversationId,
                iconName: captureMode == .audio ? "mic.fill" : "video.fill",
                onTap: onToggleCaptureMode,
                onHoldStart: onHoldStart,
                onHoldEnd: onHoldEnd
            )
            .disabled(uploading)
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button(action: onCancelRecording) {
                Image(systemName: "trash")
                    .font(.system(size: 18)).foregroundStyle(KlicColor.textMuted)
                    .frame(width: 40, height: 44)
            }
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(elapsedText)
                .font(KlicFont.body()).foregroundStyle(KlicColor.textPrimary).monospacedDigit()
            Spacer()
            Text("Recording…").font(KlicFont.caption(12)).foregroundStyle(KlicColor.textMuted)
            Button(action: onSendVoice) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            }
        }
    }

    private var elapsedText: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// §15.1: reports the input container's laid-out height for the dynamic radius.
private struct ComposerInputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct CaptureRecordButton: View {
    @ObservedObject private var chatTheme = ChatThemeStore.shared
    var conversationId: String? = nil
    let iconName: String
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    @State private var isHolding = false

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(KlicColor.onPrimary)
            .frame(width: 44, height: 44)
            .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            .scaleEffect(isHolding ? 1.08 : 1)
            .contentShape(Circle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.18)
                    .onEnded { _ in
                        isHolding = true
                        onHoldStart()
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        if isHolding {
                            isHolding = false
                            onHoldEnd()
                        } else {
                            onTap()
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.12), value: isHolding)
    }
}
