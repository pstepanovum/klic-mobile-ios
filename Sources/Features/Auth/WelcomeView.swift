import SwiftUI
import Lottie
import Inject

struct WelcomeView: View {
    @ObserveInjection var inject
    @Environment(\.colorScheme) private var colorScheme
    let onGetStarted: () -> Void

    private var ornamentTint: Color {
        colorScheme == .dark ? Color(hex: 0x232323) : Color(hex: 0xEAEAEA)
    }

    var body: some View {
        ZStack {
            KlicColor.background.ignoresSafeArea()

            // Background ornament (§0): the same "12" Lottie loop, blown up 5x and
            // recolored to a flat monochrome tint via alpha-masking so it reads as
            // texture rather than an illustration competing with the content on top.
            Rectangle()
                .fill(ornamentTint)
                .frame(width: 320 * 5, height: 320 * 5)
                .mask(
                    LottieView(animation: .named("12"))
                        .playing(loopMode: .loop)
                        .frame(width: 320 * 5, height: 320 * 5)
                )
                .offset(x: 20)
                .allowsHitTesting(false)

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
        }
        .enableInjection()
    }
}
