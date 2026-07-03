import SwiftUI
import Lottie
import Inject

struct WelcomeView: View {
    @ObserveInjection var inject
    @Environment(\.colorScheme) private var colorScheme
    let onGetStarted: () -> Void

    /// Ornament geometry: a full-bleed background texture, nudged right of center.
    /// Values are expressed relative to `ornamentReferenceDimension` (the longer
    /// side of the iPhone canvas they were tuned against) so the same visual
    /// "zoom level" carries over to larger canvases like iPad instead of staying
    /// pinned to a flat point value.
    private static let ornamentReferenceDimension: CGFloat = 844
    private static let ornamentShiftX: CGFloat = 200
    private static let ornamentShiftY: CGFloat = -150
    /// Fixed render size Lottie draws the mask at before it's blown up via
    /// `.scaleEffect`. Growing the ornament by pumping the LottieView's own
    /// `.frame()` doesn't work — lottie-ios's SwiftUI wrapper silently stops
    /// honoring layout sizes much past its authored composition, so past a
    /// point the mask just stopped growing no matter how big that constant got.
    /// Rendering at a fixed, reasonable size and scaling the *rasterized* result
    /// with a real transform sidesteps that.
    private static let ornamentDesignSide: CGFloat = 2000
    /// How many times bigger than `ornamentDesignSide` the ornament renders, at
    /// the reference canvas size. Empirically, stacking `.mask()` under a
    /// `.scaleEffect` on this Lottie view goes fully transparent somewhere
    /// between 4.5x-6.5x of `ornamentDesignSide` — `ornamentMaxZoom` keeps every
    /// canvas size (including scaled-up iPad) comfortably under that ceiling.
    private static let ornamentZoom: CGFloat = 1.7
    private static let ornamentMaxZoom: CGFloat = 2.4

    private var ornamentTint: Color {
        colorScheme == .dark ? Color(hex: 0x232323) : Color(hex: 0xEAEAEA)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                Image("KlicLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88)

                VStack(spacing: 10) {
                    Text("Talk. Chat. Connect.")
                        .font(KlicFont.banger(34))
                        .foregroundStyle(KlicColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .tracking(0.5)

                    Text("Crystal-clear calls and instant messages,\nall in one place.")
                        .font(KlicFont.expandedMedium(13))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.top, 20)
                .padding(.horizontal, 32)
            }

            Spacer()

            PillButton(
                title: String(localized: "Get Started"),
                fill: AuthStyle.ctaRed,
                font: KlicFont.expandedMedium(17),
                action: onGetStarted
            )
            .padding(.horizontal, 32)
            .padding(.bottom, 20)

            Text("Free forever · No ads · Private by design")
                .font(KlicFont.caption(12))
                .foregroundStyle(AuthStyle.smallText)
                .padding(.bottom, 48)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background ornament: the "12" Lottie loop as a giant flat-tinted texture.
        // It lives in .background so its enormous frame can never participate in
        // layout — as a ZStack sibling it inflated the stack's reported size and
        // pushed the bottom-pinned CTA off-screen. Clipped to the screen, and
        // hit-testing disabled so it can never swallow taps meant for the button.
        .background {
            GeometryReader { geo in
                let scale = max(geo.size.width, geo.size.height) / Self.ornamentReferenceDimension
                let zoomFactor = min(Self.ornamentZoom * scale, Self.ornamentMaxZoom)

                ZStack {
                    KlicColor.background

                    Rectangle()
                        .fill(ornamentTint)
                        .frame(width: Self.ornamentDesignSide, height: Self.ornamentDesignSide)
                        .scaleEffect(zoomFactor)
                        .mask(
                            LottieView(animation: .named("12"))
                                .playing(loopMode: .loop)
                                .frame(width: Self.ornamentDesignSide, height: Self.ornamentDesignSide)
                                .scaleEffect(zoomFactor)
                        )
                        .offset(x: Self.ornamentShiftX * scale, y: Self.ornamentShiftY * scale)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .enableInjection()
    }
}
