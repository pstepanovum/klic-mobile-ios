import SwiftUI
import Lottie
import Inject

struct WelcomeView: View {
    @ObserveInjection var inject
    @Environment(\.colorScheme) private var colorScheme
    let onGetStarted: () -> Void

    /// Ornament geometry: the Lottie's original on-page size was 320pt; the design
    /// blows it up into a full-bleed background texture, nudged right of center.
    private static let ornamentSide: CGFloat = 320 * 15
    private static let ornamentShift: CGFloat = 120

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
                        .font(KlicFont.body())
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
                font: KlicFont.expandedMedium(17),
                action: onGetStarted
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 20)

            Text("Free forever · No ads · Private by design")
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
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
            ZStack {
                KlicColor.background

                Rectangle()
                    .fill(ornamentTint)
                    .frame(width: Self.ornamentSide, height: Self.ornamentSide)
                    .mask(
                        LottieView(animation: .named("12"))
                            .playing(loopMode: .loop)
                            .frame(width: Self.ornamentSide, height: Self.ornamentSide)
                    )
                    .offset(x: Self.ornamentShift)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .enableInjection()
    }
}
