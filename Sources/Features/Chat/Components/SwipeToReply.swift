import SwiftUI
import UIKit

/// §15.3: interactive swipe-LEFT-to-reply on message rows (own and peer, every
/// bubble kind — text, media/bento, voice, files, stickers).
///
/// Why a UIKit pan and not a SwiftUI `DragGesture`:
/// - A SwiftUI `DragGesture` engages on movement in ANY direction once it clears
///   `minimumDistance`; you can only inspect the axis in `onChanged`, which fires
///   AFTER the gesture has already recognized. On iOS 18+ a `DragGesture` attached to
///   any subview of a `ScrollView` makes the ScrollView ignore the vertical pan for
///   that whole touch (FB14688465) — so a drag that starts on a bubble locks the list,
///   and `.simultaneousGesture` / a larger `minimumDistance` do NOT fix it. Media
///   bubbles fill the row, so nearly every drag begins on one and the list froze.
/// - A `UIPanGestureRecognizer` can DECLINE to begin (`gestureRecognizerShouldBegin`)
///   the instant it has a velocity: we begin only for a clearly-horizontal LEFTWARD
///   pan and fail for everything else, so vertical/diagonal drags are never claimed and
///   the ScrollView scrolls untouched. Taps and long-presses pass straight through
///   (the recognizer only ever wakes for pans), so opening media / the action menu is
///   unaffected.
///
/// Rendering: transform-only (offset/opacity/scale) — the row tracks the finger 1:1 up
/// to the trigger, then RESISTS (rubber-band, asymptotically capped). ONE crisp haptic
/// fires exactly when travel crosses the trigger; release past it opens the reply flow.
struct SwipeToReplyModifier: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void

    /// Raw finger travel (pt) that arms the reply action.
    private static let trigger: CGFloat = 52
    /// Asymptotic limit of extra displacement past the trigger.
    private static let bandRange: CGFloat = 80
    /// How quickly the rubber-band stiffens.
    private static let bandCoefficient: CGFloat = 0.4

    @State private var translation: CGFloat = 0
    @State private var hapticFired = false
    @State private var haptic = UIImpactFeedbackGenerator(style: .medium)

    /// 0 → resting, 1 → trigger reached (drives the badge reveal).
    private var progress: CGFloat {
        min(1, max(0, -translation / Self.trigger))
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            replyBadge
            content
                .offset(x: translation)
        }
        // The pan recognizer is installed on the row's backing view (via the
        // passthrough host below), so it observes the whole bubble without ever
        // intercepting taps/long-press. It only begins on a horizontal-left drag,
        // leaving every vertical drag to the enclosing ScrollView.
        .background {
            if enabled {
                HorizontalSwipeGesture(
                    onBegan: {
                        haptic.prepare()
                        hapticFired = false
                    },
                    onChanged: { dx in
                        let leftward = max(0, -dx)
                        translation = -Self.rubberBanded(leftward)
                        if leftward >= Self.trigger, !hapticFired {
                            hapticFired = true
                            haptic.impactOccurred()
                        }
                    },
                    onEnded: { dx in
                        let recognized = -dx >= Self.trigger
                        hapticFired = false
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            translation = 0
                        }
                        if recognized { onReply() }
                    }
                )
            }
        }
    }

    private var replyBadge: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KlicColor.textPrimary)
            .frame(width: 30, height: 30)
            .background(KlicColor.surfaceRaised, in: Circle())
            .opacity(min(1, progress * 1.2))
            .scaleEffect(0.65 + 0.35 * min(1, progress * 1.2))
            // Slides in alongside the retreating bubble instead of popping in place.
            .offset(x: 12 * (1 - progress))
            .allowsHitTesting(false)
    }

    /// Finger travel → displacement: linear up to the trigger, then the excess is
    /// compressed onto an asymptote `bandRange` away — displacement keeps growing
    /// with the finger but ever more slowly.
    private static func rubberBanded(_ travel: CGFloat) -> CGFloat {
        guard travel > trigger else { return travel }
        let excess = travel - trigger
        return trigger + (1 - 1 / (excess * bandCoefficient / bandRange + 1)) * bandRange
    }
}

/// UIKit-backed horizontal-left pan that never steals the ScrollView's vertical scroll.
///
/// The representable renders an invisible, NON-interactive host (its `hitTest` returns
/// nil, so it never wins a tap). The pan recognizer is instead added to the host's
/// superview — the row-sized backing view — and scoped back to the host's bounds via
/// the delegate, so it fires only for drags that start on THIS row's bubble.
private struct HorizontalSwipeGesture: UIViewRepresentable {
    var onBegan: () -> Void = {}
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughHostView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        // The superview may not have existed yet at make time — retry until attached.
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void
        private weak var pan: UIPanGestureRecognizer?
        private weak var host: UIView?

        init(
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(to view: UIView) {
            host = view
            guard pan == nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.pan == nil else { return }
                // Install on the row's backing view so the whole bubble is covered; the
                // delegate below re-scopes recognition to this row's bounds.
                let target = view.superview ?? view
                let recognizer = UIPanGestureRecognizer(
                    target: self, action: #selector(self.handle(_:))
                )
                recognizer.delegate = self
                target.addGestureRecognizer(recognizer)
                self.pan = recognizer
            }
        }

        func detach() {
            if let pan, let view = pan.view {
                view.removeGestureRecognizer(pan)
            }
            pan = nil
            host = nil
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            let reference = host ?? gesture.view
            let translationX = gesture.translation(in: reference).x
            switch gesture.state {
            case .began:
                onBegan()
                onChanged(translationX)
            case .changed:
                onChanged(translationX)
            case .ended, .cancelled, .failed:
                onEnded(translationX)
            default:
                break
            }
        }

        /// The decisive gate: begin ONLY for a dominantly-horizontal LEFTWARD pan that
        /// starts inside this row. Anything vertical/diagonal/rightward fails here, so
        /// the ScrollView keeps the touch and scrolls normally.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let host else { return false }
            if !host.bounds.contains(pan.location(in: host)) { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }

        /// Only accept touches that land on this row (the recognizer lives on a shared
        /// ancestor, so keep every other row's drags out of it).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let host else { return false }
            return host.bounds.contains(touch.location(in: host))
        }

        /// Coexist with the ScrollView's pan so arbitration never deadlocks; the
        /// shouldBegin gate above is what actually restricts us to horizontal.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}

/// Invisible host that never intercepts touches itself — the pan recognizer is attached
/// to its superview, so taps and long-presses fall straight through to the bubble.
private final class PassthroughHostView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

extension View {
    /// Swipe LEFT on the row to start an interactive reply (§15.3).
    func swipeToReply(enabled: Bool = true, onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(enabled: enabled, onReply: onReply))
    }
}
