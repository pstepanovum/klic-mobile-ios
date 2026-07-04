import SwiftUI
import AVFoundation

/// §16.2: circular playback bubble for round video messages — ~212pt, no bubble
/// chrome behind it (like stickers/big-emoji), a thin progress ring around the
/// circle while playing, tap to play/pause inline WITH sound, and the usual
/// duration/time/ticks meta as scrim pills on the media.
struct VideoNoteBubbleView: View {
    let attachment: Attachment
    let time: String
    var status: String? = nil
    var edited: Bool = false
    var starred: Bool = false

    static let diameter: CGFloat = 212

    @StateObject private var player = VideoNotePlayer()
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            // The thumbnail (or a dark disc) always backs the circle so the bubble
            // never reads empty while the player is still loading its first frame.
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black.opacity(0.85)
            }
            if player.isActive {
                VideoNotePlayerLayerView(player: player.avPlayer)
            }

            if !player.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.35), radius: 6)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(Circle())
        .overlay {
            // Thin progress ring around the circle while playing (§16.2).
            if player.isActive {
                Circle()
                    .trim(from: 0, to: max(player.progress, 0.02))
                    .stroke(KlicColor.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)
                    .animation(.linear(duration: 0.12), value: player.progress)
            }
        }
        .overlay(alignment: .bottomLeading) { durationPill }
        .overlay(alignment: .bottomTrailing) { metaPill }
        .contentShape(Circle())
        .onTapGesture { player.toggle(attachment: attachment) }
        .task(id: attachment.id) {
            if thumbnail == nil {
                thumbnail = await VideoThumbnailer.thumbnail(for: attachment)
            }
        }
        .onDisappear { player.stop() }
    }

    private var durationPill: some View {
        Text(player.isActive ? clock(player.currentSeconds) : clock(Double(attachment.durationMs ?? 0) / 1000))
            .font(KlicFont.caption(11))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(10)
    }

    private var metaPill: some View {
        HStack(spacing: 3) {
            if starred { StarIndicator(onPrimary: true) }
            if edited {
                Text("edited")
                    .font(KlicFont.caption(11))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(time)
                .font(KlicFont.caption(11))
                .foregroundStyle(.white)
            if let status {
                MessageTicks(status: status, onPrimary: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(10)
    }

    private func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One round-video player: streams the cached local file when present (falls back to
/// the presigned URL), plays WITH sound, publishes progress for the ring.
@MainActor
private final class VideoNotePlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var isActive = false      // a player item is loaded (paused or playing)
    @Published var progress: Double = 0
    @Published var currentSeconds: Double = 0

    let avPlayer = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(attachment: Attachment) {
        if isActive {
            if isPlaying {
                avPlayer.pause()
                isPlaying = false
            } else {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                avPlayer.play()
                isPlaying = true
            }
            return
        }
        Task { await start(attachment: attachment) }
    }

    private func start(attachment: Attachment) async {
        let source = AttachmentFileStore.shared.cachedURL(for: attachment) ?? URL(string: attachment.url)
        guard let source else { return }
        // Stop any voice note that's playing — one audio stream at a time.
        AudioPlaybackManager.shared.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: source)
        avPlayer.replaceCurrentItem(with: item)
        isActive = true
        isPlaying = true
        avPlayer.play()

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, let item = self.avPlayer.currentItem else { return }
                let duration = item.duration.seconds
                self.currentSeconds = time.seconds
                self.progress = duration > 0 && duration.isFinite ? time.seconds / duration : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        if let timeObserver { avPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        isActive = false
        isPlaying = false
        progress = 0
        currentSeconds = 0
    }
}

/// AVPlayerLayer host — fills the circle (the video is square, so aspect-fill is lossless).
private struct VideoNotePlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
