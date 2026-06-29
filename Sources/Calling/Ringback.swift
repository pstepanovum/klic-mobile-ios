import Foundation
import AVFoundation

/// Plays the outgoing ringback tone — the sound the caller hears while the call says "Calling…"
/// and we wait for the callee to answer. Loops the bundled ring sound on the active call audio
/// session and is stopped the instant the call connects, fails, or is canceled.
@MainActor
final class Ringback {
    static let shared = Ringback()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil, let url = Bundle.main.url(forResource: "ring", withExtension: "caf") else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.prepareToPlay()
            p.play()
            player = p
            APIClient.mobileDiagnostic(event: "callkit.ringback.start")
        } catch {
            APIClient.mobileDiagnostic(event: "callkit.ringback.failed", detail: String(describing: error))
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        APIClient.mobileDiagnostic(event: "callkit.ringback.stop")
    }
}
