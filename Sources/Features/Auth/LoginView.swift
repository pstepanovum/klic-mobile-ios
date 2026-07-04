import SwiftUI
import Inject

/// Login page — split out of the old toggle-mode AuthView. Visual restructure only;
/// wiring (session.login, passkey sign-in, error surfacing) is unchanged.
struct LoginView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @Environment(\.colorScheme) private var colorScheme

    @State private var username = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var passkeyBusy = false

    var body: some View {
        AuthScaffold(artworkName: "AuthLoginArt", tipFraction: 0.47) {
            VStack(spacing: 0) {
                Text("Login")
                    .font(KlicFont.expandedMedium(30))
                    .foregroundStyle(AuthStyle.titleColor(colorScheme))

                Text("Welcome back — sign in to keep chatting.")
                    .font(KlicFont.body(15))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    AuthTextField(
                        prefix: "@",
                        placeholder: String(localized: "Username"),
                        text: $username,
                        contentType: .username
                    )
                    AuthTextField(
                        placeholder: String(localized: "Password"),
                        text: $password,
                        isSecure: true,
                        contentType: .password
                    )
                }
                .padding(.top, 28)

                PillButton(
                    title: String(localized: "Login"),
                    fill: AuthStyle.ctaRed,
                    font: KlicFont.expandedMedium(17),
                    isLoading: isSubmitting
                ) {
                    Task { await submit() }
                }
                .padding(.top, 20)

                // Passkey sign-in (§10.4) — kept as a tasteful secondary row under the
                // primary button; the mock itself omits it.
                Button {
                    Task { await signInWithPasskey() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 14, weight: .medium))
                        Text(passkeyBusy ? String(localized: "Waiting for passkey…") : String(localized: "Sign in with a passkey"))
                            .font(KlicFont.medium(14))
                    }
                    .foregroundStyle(AuthStyle.smallText)
                }
                .buttonStyle(.plain)
                .disabled(passkeyBusy)
                .padding(.top, 16)

                if let error = session.errorMessage {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }

                NavigationLink {
                    SignUpView()
                } label: {
                    Text("Create an account")
                        .font(KlicFont.medium(14))
                        .foregroundStyle(AuthStyle.smallText)
                        .underline()
                }
                .padding(.top, 18)
            }
            .padding(.horizontal, 32)
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .toolbar(.hidden, for: .navigationBar)
        .enableInjection()
    }

    private func submit() async {
        session.errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        await session.login(username: username, password: password)
    }

    // MARK: Passkey sign-in (§10.4)

    private func signInWithPasskey() async {
        passkeyBusy = true
        defer { passkeyBusy = false }
        do {
            let response = try await PasskeyService.shared.signInWithPasskey()
            session.signIn(with: response)
        } catch is CancellationError {
            // User dismissed the system sheet.
        } catch let e as APIError {
            session.errorMessage = e.userMessage
        } catch {
            session.errorMessage = (error as NSError).localizedDescription
        }
    }
}
