import SwiftUI
import Inject

/// Shared backdrop for Login / Sign Up: a huge circle ("scaled rounded circle") anchored
/// below the screen, its top arc rising in to form a bottom content sheet, with the page
/// artwork centered behind it in the exposed background area.
///
/// `tipFraction` places the arc's top tip as a fraction of screen height — smaller pushes
/// the circle (and the content that sits just below its tip) higher. Sign Up has more
/// fields than Login so it uses a smaller fraction to leave room.
struct AuthScaffold<Content: View>: View {
    @ObserveInjection var inject

    let artworkName: String
    var tipFraction: CGFloat
    /// Baseline circle radius, tuned against `referenceWidth`. Left as a stored
    /// property (rather than computed from geometry) so call sites can still
    /// override it, but the body always scales it by the actual canvas width.
    var radius: CGFloat = AuthStyle.circleRadius
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    /// §13.9: how far the art/circle/content group is risen while the keyboard is up.
    /// Driven by the keyboard-frame notifications and applied as a pure `.offset`
    /// (a render-time translation) — the heavy circle/art layers are laid out ONCE
    /// and never re-layout during the transition, so the shift stays at 60fps.
    @State private var keyboardShift: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let widthScale = geo.size.width / AuthStyle.referenceWidth
            let scaledRadius = radius * widthScale
            let artSide = Self.artSide(for: geo.size)
            // The form below isn't scrollable, so on short canvases (landscape
            // iPad/iPhone) the dome is flattened toward the top to guarantee
            // enough room for it, rather than letting it run under the fold.
            let effectiveTipFraction = geo.size.height < 700 ? tipFraction * 0.6 : tipFraction
            let tipY = max(60, geo.size.height * effectiveTipFraction)
            let topInset = tipY + 44
            // Space available for the form between the circle's tip and the
            // bottom edge. On a compact iPhone this is barely more than the
            // form's own height, so centering it here is a no-op; on a much
            // taller canvas (iPad) it keeps the form from reading as glued to
            // the top of a mostly-empty sheet.
            let contentRegionHeight = max(geo.size.height - topInset - 24, 0)

            ZStack(alignment: .top) {
                KlicColor.background
                    .ignoresSafeArea()

                // The whole scene (art + sheet circle + form) rises as ONE offset
                // group while the keyboard animates in/out — no per-frame layout.
                Group {
                    Image(artworkName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: artSide)
                        .position(x: geo.size.width / 2, y: tipY * 0.5)
                        .allowsHitTesting(false)

                    Circle()
                        .fill(AuthStyle.circleFill(colorScheme))
                        .frame(width: scaledRadius * 2, height: scaledRadius * 2)
                        .position(x: geo.size.width / 2, y: tipY + scaledRadius)
                        .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        content()
                    }
                    .frame(maxWidth: AuthStyle.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .frame(height: contentRegionHeight, alignment: .center)
                    .padding(.top, topInset)
                }
                .offset(y: -keyboardShift)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // Container safe area (status bar + home indicator) is ignored on both edges
        // so the art/circle/background bleed fully to the screen edges. The keyboard
        // region is ALSO ignored (§13.9): SwiftUI's inset-driven avoidance re-layouts
        // the whole scaffold every frame of the keyboard animation (the visible
        // freeze/jump) — instead the keyboard notifications below drive a matched,
        // offset-only rise.
        .ignoresSafeArea(.container, edges: .all)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            // Rise by the keyboard overlap minus the home-indicator band the form
            // already clears — same travel the safe-area path used to produce.
            let target = max(0, (screen.maxY - end.origin.y) - 34)
            guard target != keyboardShift else { return }
            // UIKit's keyboard animation is a spring with these exact parameters —
            // matching it keeps the form glued to the keyboard's own curve.
            withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
                keyboardShift = target
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .enableInjection()
    }

    /// Background artwork size: ~4x its previous footprint on a compact iPhone
    /// canvas (a bold bleeding illustration, matching the Welcome ornament's
    /// oversized-background language). On iPad's much bigger canvas the ratio
    /// is tripled again so the art keeps filling the generous empty space
    /// instead of reading as a small accent floating in a sea of background.
    private static func artSide(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        let ratio: CGFloat = shortSide < 600 ? 2.8 : 3.9
        return shortSide * ratio
    }
}
