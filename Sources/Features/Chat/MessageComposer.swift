import SwiftUI

/// The chat input row: attach (+), text pill with inline sticker button, and a send/mic
/// button. The row itself has no background — the controls float on the chat; only the
/// individual controls (pill, buttons) carry their own fill.
struct MessageComposer: View {
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
    let onAttach: () -> Void
    let onStickers: () -> Void
    let onSend: () -> Void
    let onToggleCaptureMode: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onCancelRecording: () -> Void
    let onSendVoice: () -> Void

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

            // Input pill with the emoji/sticker button tucked inside on the right.
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
            .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))

            let canSend = hasPendingAttachments || !draft.trimmingCharacters(in: .whitespaces).isEmpty
            composerActionButton(canSend: canSend)
        }
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
    }

    @ViewBuilder
    private func composerActionButton(canSend: Bool) -> some View {
        if canSend {
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(KlicColor.primary, in: Circle())
            }
            .disabled(uploading)
        } else {
            CaptureRecordButton(
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
                    .background(KlicColor.primary, in: Circle())
            }
        }
    }

    private var elapsedText: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CaptureRecordButton: View {
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
            .background(KlicColor.primary, in: Circle())
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
