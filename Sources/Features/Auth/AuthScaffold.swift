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

    var body: some View {
        GeometryReader { geo in
            let widthScale = geo.size.width / AuthStyle.referenceWidth
            let scaledRadius = radius * widthScale
            let artSide = Self.artSide(for: geo.size)
            // The form below isn't scrollable, so on short canvases (landscape
            // iPad/iPhone) the dome is flattened toward the top to guarantee
            // enough room for it, rather than letting it run under the fold.
            let effectiveTipFraction = geo.size.height < 700 ? tipFraction * 0.6 : tipFraction
            // Keyboard avoidance: SwiftUI reports an open keyboard as extra bottom
            // safe-area inset rather than resizing the frame (the GeometryReader is
            // deliberately NOT told to ignore that region below). Rise the sheet,
            // art and content by that amount so the fields never end up hidden
            // under the keyboard instead of just sitting still.
            let keyboardShift = max(0, geo.safeAreaInsets.bottom - 34)
            let tipY = max(60, geo.size.height * effectiveTipFraction - keyboardShift)
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
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeOut(duration: 0.25), value: keyboardShift)
        }
        // Container safe area (status bar + home indicator) is ignored on both
        // edges so the art/circle/background bleed fully to the screen edges —
        // the KEYBOARD safe-area region is deliberately left alone (a bare
        // `.ignoresSafeArea()` would swallow that too and break the keyboard
        // avoidance above).
        .ignoresSafeArea(.container, edges: .all)
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
