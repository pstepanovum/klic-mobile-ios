import SwiftUI
import AVFoundation

// §16.2: shared pieces of the hold-to-record lock system — the floating padlock,
// the slide-to-cancel hint, and the round-video recording overlay.

/// The floating padlock above the record button: OPEN and tilted while unlocked,
/// closing/straightening as the finger approaches the lock threshold, snapping
/// closed (~250ms ease-out) when the recording locks.
struct RecordingPadlock: View {
    /// 0 → open/tilted, 1 → closed (RecordingSession.lockProgress).
    let progress: CGFloat
    let locked: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Image(systemName: "lock.open.fill")
                    .opacity(locked ? 0 : Double(1 - progress))
                Image(systemName: "lock.fill")
                    .opacity(locked ? 1 : Double(progress))
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(locked ? KlicColor.onPrimary : KlicColor.textPrimary)
            .rotationEffect(.degrees(locked ? 0 : Double(-18 * (1 - progress))))

            if !locked {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(KlicColor.textMuted)
                    .opacity(Double(max(0, 1 - progress * 1.6)))
            }
        }
        .padding(.vertical, 12)
        .frame(width: 40)
        .background(
            locked ? AnyShapeStyle(KlicColor.primary) : AnyShapeStyle(KlicColor.surfaceRaised),
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .scaleEffect(locked ? 1.08 : 1)
        .animation(.easeOut(duration: 0.25), value: locked)
        // Creep toward the finger as the lock approaches.
        .offset(y: -10 * progress)
    }
}

/// "Slide to cancel" hint with a left chevron — dragged along with the finger,
/// fading as the cancel threshold approaches.
struct SlideToCancelHint: View {
    /// Leftward finger travel (≤ 0) — RecordingSession.cancelTranslation.
    let translation: CGFloat

    private var fade: Double {
        Double(max(0, 1 - (-translation / RecordingSession.Thresholds.cancel) * 1.3))
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
            Text("Slide to cancel")
                .font(KlicFont.caption(13))
        }
        .foregroundStyle(KlicColor.textMuted)
        .opacity(fade)
        .offset(x: translation * 0.75)
    }
}

/// Pulsing red recording dot.
struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Live camera preview host for the circular viewfinder.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {}

    final class PreviewHostView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// §16.2: the round-video recording overlay — circular live preview (front camera
/// default), progress ring showing elapsed/60s, timer + red dot, flip-camera
/// button, and the same slide-to-cancel / slide-up-to-lock system as audio.
struct VideoNoteRecordingOverlay: View {
    @ObservedObject var recorder: VideoNoteRecorder
    @ObservedObject var session: RecordingSession
    var onFlip: () -> Void = {}
    var onCancel: () -> Void = {}
    var onSend: () -> Void = {}

    private let circleSize: CGFloat = 280

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                ZStack {
                    Group {
                        if recorder.isStub {
                            // Simulator: no camera — placeholder keeps the whole
                            // flow (ring, timer, lock system) verifiable.
                            ZStack {
                                Color(white: 0.14)
                                VStack(spacing: 10) {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Text("No camera on this device")
                                        .font(KlicFont.caption(12))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        } else {
                            CameraPreviewView(session: recorder.captureSession)
                        }
                    }
                    .frame(width: circleSize, height: circleSize)
                    .clipShape(Circle())

                    // Progress ring: elapsed toward the 60s cap.
                    Circle()
                        .trim(from: 0, to: max(0.003, recorder.elapsed / RecordingSession.Thresholds.videoCap))
                        .stroke(KlicColor.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: circleSize + 14, height: circleSize + 14)
                        .animation(.linear(duration: 0.1), value: recorder.elapsed)
                }

                HStack(spacing: 10) {
                    RecordingDot()
                    Text(clock(recorder.elapsed))
                        .font(KlicFont.headline(16))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                Button(action: onFlip) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                // While holding: the slide-to-cancel hint; once locked: Cancel + Send.
                if session.phase == .locked {
                    HStack {
                        Button(action: onCancel) {
                            Text("Cancel")
                                .font(KlicFont.headline(15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 11)
                                .background(.white.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(action: onSend) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(KlicColor.onPrimary)
                                .frame(width: 52, height: 52)
                                .background(KlicColor.primary, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                } else {
                    SlideToCancelHint(translation: session.cancelTranslation)
                        .padding(.bottom, 34)
                }
            }
        }
        .transition(.opacity)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
