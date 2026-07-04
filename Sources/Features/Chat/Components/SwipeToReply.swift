import SwiftUI
import UIKit

/// §15.3: interactive swipe-LEFT-to-reply on message rows (own and peer, every
/// bubble kind — text, media/bento, voice, files, stickers).
///
/// Gesture anatomy:
/// - Scroll-vs-swipe disambiguation: the very first movement decides the axis. A
///   mostly-vertical drag is rejected for the rest of the touch so the list scrolls
///   untouched; a mostly-horizontal leftward drag engages the gesture.
/// - The row tracks the finger 1:1 up to the trigger distance, then RESISTS: the
///   displacement past the trigger grows sublinearly (rubber-band), asymptotically
///   capped, so the bubble never runs away.
/// - A reply badge fades/scales in behind the row's trailing edge as progress builds.
/// - ONE crisp haptic exactly when the raw finger travel crosses the trigger; the
///   flag re-arms only when a new touch begins, so it never re-fires while held.
/// - Release past the trigger opens the reply flow; anything less springs back.
/// - Transform-only rendering (offset/opacity/scale) — no per-frame re-layout.
struct SwipeToReplyModifier: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void

    /// Raw finger travel (pt) that arms the reply action.
    private static let trigger: CGFloat = 52
    /// Asymptotic limit of extra displacement past the trigger.
    private static let bandRange: CGFloat = 80
    /// How quickly the rubber-band stiffens.
    private static let bandCoefficient: CGFloat = 0.4
    /// Movement before the drag is recognized at all (lets taps through).
    private static let activationDistance: CGFloat = 12

    private enum AxisLock {
        case undecided
        case horizontal
        /// Mostly-vertical start — ignore this touch entirely; the list scrolls.
        case rejected
    }

    @State private var translation: CGFloat = 0
    @State private var axisLock: AxisLock = .undecided
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
        .gesture(dragGesture, including: enabled ? .all : .subviews)
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

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: Self.activationDistance)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if axisLock == .undecided {
                    // First decision wins for the whole touch: leftward and clearly
                    // more horizontal than vertical, or the list keeps the drag.
                    if dx < 0, abs(dx) > abs(dy) {
                        axisLock = .horizontal
                        haptic.prepare()
                    } else {
                        axisLock = .rejected
                    }
                }
                guard axisLock == .horizontal else { return }

                translation = -Self.rubberBanded(max(0, -dx))

                if -dx >= Self.trigger, !hapticFired {
                    hapticFired = true
                    haptic.impactOccurred()
                }
            }
            .onEnded { value in
                let recognized = axisLock == .horizontal
                    && -value.translation.width >= Self.trigger
                axisLock = .undecided
                hapticFired = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    translation = 0
                }
                if recognized {
                    onReply()
                }
            }
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

extension View {
    /// Swipe LEFT on the row to start an interactive reply (§15.3).
    func swipeToReply(enabled: Bool = true, onReply: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(enabled: enabled, onReply: onReply))
    }
}
