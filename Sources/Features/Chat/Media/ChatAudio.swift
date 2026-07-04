import SwiftUI
import AVFoundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?
    private var samples: [Float] = []

    func start() {
        // H4: never record a voice note while a call is active. Recording sets/activates the
        // shared AVAudioSession (playAndRecord/.defaultToSpeaker) and would fight LiveKit for
        // the call's session — the "background answer → no audio" bug. The call owns the mic.
        guard CallKitManager.shared.activeCall == nil else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.begin() }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder = rec
        fileURL = url
        rec.isMeteringEnabled = true
        rec.record()
        isRecording = true
        elapsed = 0
        samples = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let clamped = max(-60.0, min(0.0, Double(db)))
                self.samples.append(Float((clamped + 60.0) / 60.0))
            }
        }
    }

    func stop() -> (data: Data, durationMs: Int, waveform: Data)? {
        timer?.invalidate()
        timer = nil
        guard let recorder, let fileURL else {
            isRecording = false
            return nil
        }
        let duration = recorder.currentTime
        let captured = samples
        recorder.stop()
        self.recorder = nil
        isRecording = false
        samples = []
        // H4: only deactivate the shared session when NO call is live. Deactivating it mid-call
        // would tear down the CallKit-owned call session (silent call). start() already blocks
        // recording during a call, so this is a defensive guard for the interleaved case.
        if CallKitManager.shared.activeCall == nil {
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        guard duration > 0.4, let data = try? Data(contentsOf: fileURL) else { return nil }
        return (data, Int(duration * 1000), packWaveform(captured))
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        samples = []
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

@MainActor
final class AudioPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackManager()

    @Published var playingId: String?
    @Published var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, url: String) {
        if playingId == id {
            stop()
            return
        }
        Task { await play(id: id, url: url) }
    }

    private func play(id: String, url: String) async {
        // H4: don't play voice notes while a call is active — switching the shared session to
        // .playback and re-activating it would steal the call's audio session and drop call audio.
        guard CallKitManager.shared.activeCall == nil else { return }
        stop()
        guard let url = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let player = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.delegate = self
        self.player = player
        playingId = id
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingId = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
