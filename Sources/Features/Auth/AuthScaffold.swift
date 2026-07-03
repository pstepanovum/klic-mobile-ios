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
    var radius: CGFloat = AuthStyle.circleRadius
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                KlicColor.background
                    .ignoresSafeArea()

                Image(artworkName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(geo.size.width * 0.7, 300))
                    .position(x: geo.size.width / 2, y: geo.size.height * tipFraction * 0.5)
                    .opacity(colorScheme == .dark ? 0.85 : 1)
                    .allowsHitTesting(false)

                Circle()
                    .fill(AuthStyle.circleFill(colorScheme))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: geo.size.width / 2, y: geo.size.height * tipFraction + radius)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    content()
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * tipFraction + 44)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .enableInjection()
    }
}
