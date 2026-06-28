import SwiftUI
import Lottie

struct AuthView: View {
    @EnvironmentObject var session: AppSession

    @State private var isRegistering = false
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LottieView(animation: LottieAnimation.named("12", subdirectory: "Animations"))
                    .playing(loopMode: .loop)
                    .frame(height: 260)
                    .padding(.top, 48)

                Image("KlicLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130)
                    .padding(.top, 20)

                Text(isRegistering ? "Create your account" : "Welcome back")
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textMuted)
                    .padding(.top, 10)
                    .padding(.bottom, 28)

                VStack(spacing: 12) {
                    KlicTextField(placeholder: "Username", text: $username)
                    if isRegistering {
                        KlicTextField(placeholder: "Display name", text: $displayName)
                    }
                    KlicTextField(placeholder: "Password", text: $password, isSecure: true)
                }

                if isRegistering {
                    Text("Username: 3+ characters (a–z, 0–9, . _) · Password: 8+ characters")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                PillButton(title: isRegistering ? "Sign up" : "Log in") {
                    Task {
                        if isRegistering {
                            await session.register(username: username, password: password, displayName: displayName)
                        } else {
                            await session.login(username: username, password: password)
                        }
                    }
                }
                .padding(.top, 20)

                Button(isRegistering ? "I already have an account" : "Create an account") {
                    withAnimation { isRegistering.toggle() }
                }
                .font(KlicFont.medium(14))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.top, 12)

                if let error = session.errorMessage {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .padding(.top, 8)
                }

                Spacer().frame(height: 40)
            }
            .padding(.horizontal, 28)
        }
        .background(KlicColor.background.ignoresSafeArea())
    }
}
