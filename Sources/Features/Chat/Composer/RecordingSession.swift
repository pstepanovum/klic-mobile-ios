import SwiftUI

/// §16.2: shared state for the hold-to-record gesture — one system for BOTH audio
/// and round-video recording. Tracks the hold phase, the raw finger translation
/// (drives the slide-to-cancel hint and the padlock morph), and the lock state.
///
/// Thresholds: sliding UP locks at 110pt of travel (the padlock closes over the
/// last ~105pt), releasing above 60pt (or a fast upward flick) also locks; sliding
/// LEFT past 150pt (or a fast left flick, or 100pt at release) cancels.
@MainActor
final class RecordingSession: ObservableObject {
    enum Mode: String { case audio, video }
    enum Phase: Equatable { case idle, holding, locked }

    @Published var mode: Mode = RecordingSession.sessionMode
    @Published var phase: Phase = .idle
    /// Raw finger translation while holding (zeroed when idle/locked).
    @Published var drag: CGSize = .zero

    /// 0 → padlock open/tilted, 1 → closed. Snaps to 1 on lock.
    var lockProgress: CGFloat {
        phase == .locked ? 1 : min(1, max(0, -drag.height / Thresholds.lockRamp))
    }
    /// Leftward finger travel (≤0) — offsets the slide-to-cancel hint / button.
    var cancelTranslation: CGFloat { min(0, drag.width) }
    var isActive: Bool { phase != .idle }

    enum Thresholds {
        /// Upward travel that commits the lock mid-drag.
        static let lock: CGFloat = 110
        /// The padlock morph ramps over this distance.
        static let lockRamp: CGFloat = 105
        /// Upward travel that locks when the finger RELEASES there.
        static let releaseLock: CGFloat = 60
        /// Leftward travel that cancels mid-drag.
        static let cancel: CGFloat = 150
        /// Leftward travel that cancels when the finger releases there.
        static let releaseCancel: CGFloat = 100
        /// A fast flick (pt/s) counts as the full gesture.
        static let flickVelocity: CGFloat = 400
        /// Auto-lock just before the cap so it never rips the button from a held finger.
        static let autoLockAt: TimeInterval = 59
        /// Round-video hard cap (§16.2).
        static let videoCap: TimeInterval = 60
    }

    /// Mode choice persists per app session (§16.2) — not across launches.
    static var sessionMode: Mode = .audio

    func setMode(_ newMode: Mode) {
        mode = newMode
        Self.sessionMode = newMode
    }

    func reset() {
        phase = .idle
        drag = .zero
    }
}
