import SwiftUI
import UIKit
import AVFoundation

/// §16.2: the hold-to-record lock system — one set of mechanics for BOTH audio and
/// round-video recording. Slide LEFT to cancel (150pt drag or a fast left flick;
/// 100pt is enough at release), slide UP to lock (110pt drag or a fast upward
/// flick; 60pt is enough at release). Auto-locks at 59s; video hard-caps at 60s.
extension ChatView {
    func holdStart() {
        guard recSession.phase == .idle else { return }
        recSession.drag = .zero
        recSession.phase = .holding
        switch recSession.mode {
        case .audio:
            recorder.start()
        case .video:
            noteRecorder.start()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func holdDrag(_ translation: CGSize) {
        guard recSession.phase == .holding else { return }
        recSession.drag = translation
        if -translation.width >= RecordingSession.Thresholds.cancel {
            cancelRecording()
        } else if -translation.height >= RecordingSession.Thresholds.lock {
            lockRecording()
        }
    }

    func holdEnd(_ translation: CGSize, _ velocity: CGSize) {
        guard recSession.phase == .holding else { return }
        if -translation.width >= RecordingSession.Thresholds.releaseCancel
            || velocity.width <= -RecordingSession.Thresholds.flickVelocity {
            cancelRecording()
        } else if -translation.height >= RecordingSession.Thresholds.releaseLock
            || velocity.height <= -RecordingSession.Thresholds.flickVelocity {
            lockRecording()
        } else {
            // Plain release → stop and send.
            finishAndSendRecording()
        }
    }

    /// One crisp haptic; the padlock snaps closed; the finger may lift.
    func lockRecording() {
        guard recSession.phase == .holding else { return }
        recSession.phase = .locked
        recSession.drag = .zero
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func cancelRecording() {
        let mode = recSession.mode
        recSession.reset()
        switch mode {
        case .audio: recorder.cancel()
        case .video: noteRecorder.cancel()
        }
    }

    func finishAndSendRecording() {
        let mode = recSession.mode
        recSession.reset()
        switch mode {
        case .audio:
            Task { await stopAndSendVoice() }
        case .video:
            Task { await finishAndSendVideoNote() }
        }
    }

    /// §16.2: auto-lock just before the cap so the button is never ripped out from
    /// under a held finger; hard-stop video at 60s and hand it to send.
    func watchRecordingProgress(elapsed: TimeInterval, isVideo: Bool) {
        guard recSession.isActive else { return }
        if recSession.phase == .holding, elapsed >= RecordingSession.Thresholds.autoLockAt {
            lockRecording()
        }
        if isVideo, recSession.mode == .video, elapsed >= RecordingSession.Thresholds.videoCap {
            finishAndSendRecording()
        }
    }

    /// Stop the round-video recorder, wrap the square mp4 as a VIDEO_NOTE draft and
    /// ship it through the streamed upload pipeline (§13.15).
    func finishAndSendVideoNote() async {
        guard let (url, durationMs) = await noteRecorder.finish() else { return }
        let side = 400
        let preview = await videoNotePreviewImage(url)
        let draft = PendingMediaDraft(
            kind: "VIDEO_NOTE",
            contentType: "video/mp4",
            fileURL: url,
            previewImage: preview,
            width: side,
            height: side,
            durationMs: durationMs
        )
        let replyId = replyingTo?.id
        await MainActor.run {
            withAnimation { replyingTo = nil }
            startUpload(items: [draft], caption: "", replyToId: replyId)
        }
    }

    private func videoNotePreviewImage(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let (cgImage, _) = try? await generator.image(
            at: CMTime(seconds: 0.03, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
