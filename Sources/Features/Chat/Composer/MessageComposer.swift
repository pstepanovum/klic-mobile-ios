import SwiftUI
import UIKit

/// A reply target rendered INSIDE the composer's input container (§15.1).
struct ComposerReplyPreview: Equatable {
    let authorName: String
    let preview: String
}

/// §16.4: edit-mode banner rendered inside the input container, like the reply one.
struct ComposerEditPreview: Equatable {
    let original: String
}

/// The chat input row: attach (+), text pill with inline sticker button, and a send/mic
/// button. The row itself has no background — the controls float on the chat; only the
/// individual controls (pill, buttons) carry their own fill.
struct MessageComposer: View {
    // §12.3: the send/record buttons follow the chat theme's bubble accent
    // (§14.3: resolved per conversation — group > per-chat > global).
    @ObservedObject var chatTheme = ChatThemeStore.shared
    var conversationId: String? = nil

    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @ObservedObject var recorder: AudioRecorder
    /// §16.2: hold/lock/cancel state shared with the recording overlays.
    @ObservedObject var recSession: RecordingSession
    let uploading: Bool
    let hasPendingAttachments: Bool
    /// §15.1: when replying, the quoted preview lives inside the input container —
    /// one rounded shape with the banner on top and the text field below.
    var replyPreview: ComposerReplyPreview? = nil
    /// §16.4: edit mode — banner inside the input, checkmark send button.
    var editPreview: ComposerEditPreview? = nil
    /// §16.4: bumped when an edit apply is rejected (empty text) — shakes the input.
    var editShakeTrigger: Int = 0
    var onCancelReply: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    let onAttach: () -> Void
    let onStickers: () -> Void
    let onSend: () -> Void
    let onToggleCaptureMode: () -> Void
    let onHoldStart: () -> Void
    var onHoldDrag: (CGSize) -> Void = { _ in }
    var onHoldEnd: (CGSize, CGSize) -> Void = { _, _ in }
    let onCancelRecording: () -> Void
    /// Stop + send the locked recording (audio or video).
    let onSendRecording: () -> Void

    /// §15.1: measured height of the input container — drives the dynamic radius.
    @State private var inputHeight: CGFloat = 0
    /// §16.2: the mode tooltip near the mic/camera button (auto-dismisses).
    @State private var tooltipText: String?
    @State private var tooltipToken = UUID()

    private var isAudioRecording: Bool { recSession.isActive && recSession.mode == .audio }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // The leading content swaps between the normal input and the recording
            // bar, but the trailing action button (the active gesture's host view)
            // stays mounted throughout — swapping it out would cancel the touch.
            if isAudioRecording {
                audioRecordingBar
            } else {
                attachButton
                inputContainer
            }
            composerActionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
        // §16.2: floating padlock above the record button while holding (audio mode;
        // the video overlay hosts its own).
        .overlay(alignment: .bottomTrailing) {
            if recSession.phase == .holding, recSession.mode == .audio {
                RecordingPadlock(progress: recSession.lockProgress, locked: false)
                    .padding(.trailing, 12)
                    .padding(.bottom, 74)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        // §16.2: "Hold to record …" helper tooltip near the button.
        .overlay(alignment: .bottomTrailing) {
            if let tooltipText {
                Text(tooltipText)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .padding(.trailing, 10)
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: tooltipText)
        .animation(.easeInOut(duration: 0.15), value: recSession.phase)
    }

    private var attachButton: some View {
        Button(action: onAttach) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
                .frame(width: 44, height: 44)
                .background(KlicColor.surfaceRaised, in: Circle())
        }
        .disabled(uploading)
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

    // One rounded input container: optional reply/edit banner on top (§15.1/§16.4),
    // text row with the emoji/sticker button tucked inside below. Bottom-aligned so
    // the +, emoji, and send controls stay pinned to the BOTTOM as it grows.
    private var inputContainer: some View {
        VStack(spacing: 0) {
            if let edit = editPreview {
                editBanner(edit)
            } else if let reply = replyPreview {
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
        // §16.4: empty edit apply → shake, don't send.
        .modifier(ShakeEffect(shakes: CGFloat(editShakeTrigger)))
        .animation(.easeInOut(duration: 0.4), value: editShakeTrigger)
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: replyPreview)
        .animation(.easeInOut(duration: 0.15), value: editPreview)
    }

    private func replyBanner(_ reply: ComposerReplyPreview) -> some View {
        banner(
            title: String(localized: "Reply to \(reply.authorName)"),
            context: reply.preview,
            onClose: onCancelReply
        )
    }

    /// §16.4: "Edit Message" banner — same in-input pattern as the reply preview.
    private func editBanner(_ edit: ComposerEditPreview) -> some View {
        banner(
            title: String(localized: "Edit Message"),
            context: edit.original,
            onClose: onCancelEdit
        )
    }

    private func banner(title: String, context: String, onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(KlicColor.primary)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.primary)
                Text(context)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
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
    private var composerActionButton: some View {
        let canSend = hasPendingAttachments || !draft.trimmingCharacters(in: .whitespaces).isEmpty
        if recSession.phase == .locked {
            // Locked recording: prominent Send (stop + send) button.
            Button(action: onSendRecording) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            }
        } else if editPreview != nil {
            // §16.4: edit mode — checkmark apply button.
            Button(action: onSend) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            }
            .disabled(uploading)
        } else if canSend, !recSession.isActive {
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
                iconName: recSession.mode == .audio ? "mic.fill" : "video.fill",
                holding: recSession.phase == .holding,
                onTap: {
                    onToggleCaptureMode()
                    showTooltip()
                },
                onHoldStart: onHoldStart,
                onHoldDrag: onHoldDrag,
                onHoldEnd: onHoldEnd
            )
            .disabled(uploading)
        }
    }

    /// §16.2: helper tooltip with the EXACT mode strings, auto-dismissed.
    private func showTooltip() {
        // The toggle has already flipped the mode when this runs.
        tooltipText = recSession.mode == .audio
            ? String(localized: "Hold to record audio. Tap to switch to video.")
            : String(localized: "Hold to record video. Tap to switch to audio.")
        let token = UUID()
        tooltipToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if tooltipToken == token { tooltipText = nil }
        }
    }

    /// §16.2: leading composer content while recording audio — red dot + timer, then
    /// the slide-to-cancel hint (holding) or Cancel control (locked).
    private var audioRecordingBar: some View {
        HStack(spacing: 12) {
            if recSession.phase == .locked {
                Button(action: onCancelRecording) {
                    Image(systemName: "trash")
                        .font(.system(size: 18))
                        .foregroundStyle(KlicColor.danger)
                        .frame(width: 40, height: 44)
                }
            }
            RecordingDot()
            Text(elapsedText)
                .font(KlicFont.body()).foregroundStyle(KlicColor.textPrimary).monospacedDigit()
            Spacer()
            if recSession.phase == .holding {
                SlideToCancelHint(translation: recSession.cancelTranslation)
                    .padding(.trailing, 6)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
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

/// §16.4: horizontal shake for a rejected (empty) edit apply.
struct ShakeEffect: GeometryEffect {
    var amplitude: CGFloat = 7
    var shakesPerUnit: CGFloat = 3
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: amplitude * sin(shakes * .pi * shakesPerUnit * 2), y: 0
        ))
    }
}

/// §16.2: the two-mode record button. TAP toggles audio ↔ video; HOLD records with
/// live drag reporting for the slide-to-cancel / slide-up-to-lock system.
private struct CaptureRecordButton: View {
    @ObservedObject private var chatTheme = ChatThemeStore.shared
    var conversationId: String? = nil
    let iconName: String
    let holding: Bool
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldDrag: (CGSize) -> Void
    /// (translation, velocity) at finger-up.
    let onHoldEnd: (CGSize, CGSize) -> Void

    @State private var isHolding = false
    @State private var toggleHaptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(KlicColor.onPrimary)
            .frame(width: 44, height: 44)
            .background(chatTheme.bubbleColor(for: conversationId), in: Circle())
            .scaleEffect(isHolding || holding ? 1.35 : 1)
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
                    .onChanged { value in
                        guard isHolding else { return }
                        onHoldDrag(value.translation)
                    }
                    .onEnded { value in
                        if isHolding {
                            isHolding = false
                            onHoldEnd(
                                value.translation,
                                CGSize(width: value.velocity.width, height: value.velocity.height)
                            )
                        } else {
                            toggleHaptic.impactOccurred()
                            onTap()
                        }
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHolding || holding)
    }
}
