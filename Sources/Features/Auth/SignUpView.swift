import SwiftUI
import Inject

/// Sign Up page — split out of the old toggle-mode AuthView. Same circle-container
/// language as Login, but the circle sits higher since there's more content: username,
/// display name, password (+ strength meter), and the privacy-policy checkbox that
/// gates the submit button.
struct SignUpView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var agreedToPrivacy = false
    @State private var showPrivacyPolicy = false
    @State private var isSubmitting = false

    var body: some View {
        AuthScaffold(artworkName: "AuthSignupArt", tipFraction: 0.34) {
            VStack(spacing: 0) {
                Text("Sign Up")
                    .font(KlicFont.expandedMedium(30))
                    .foregroundStyle(AuthStyle.titleColor(colorScheme))

                Text("Yo! Let's create an account for you")
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
                        placeholder: String(localized: "Display name"),
                        text: $displayName,
                        contentType: .name
                    )
                    AuthTextField(
                        placeholder: String(localized: "Password"),
                        text: $password,
                        isSecure: true,
                        contentType: .newPassword
                    )

                    if !password.isEmpty {
                        strengthBar
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 24)
                .animation(.easeInOut(duration: 0.2), value: password.isEmpty)

                KlicCheckbox(isChecked: $agreedToPrivacy) { showPrivacyPolicy = true }
                    .padding(.top, 16)

                PillButton(
                    title: String(localized: "Sign up"),
                    fill: agreedToPrivacy ? AuthStyle.ctaRed : Color(hex: 0xB2B2B2),
                    font: KlicFont.expandedMedium(17),
                    isLoading: isSubmitting
                ) {
                    Task { await submit() }
                }
                .padding(.top, 18)
                .disabled(!agreedToPrivacy || isSubmitting)

                if let error = session.errorMessage {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }

                Button {
                    dismiss()
                } label: {
                    Text("I already have an account")
                        .font(KlicFont.medium(14))
                        .foregroundStyle(AuthStyle.smallText)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .padding(.horizontal, 32)
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .enableInjection()
    }

    private func submit() async {
        session.errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        await session.register(username: username, password: password, displayName: displayName)
    }

    // MARK: Password strength

    private var strength: (bars: Int, label: String, color: Color) {
        guard !password.isEmpty else { return (0, "", .clear) }
        let hasUpper   = password.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasDigit   = password.range(of: "[0-9]", options: .regularExpression) != nil
        let hasSpecial = password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
        if password.count < 8                     { return (1, "Weak",   .red) }
        if !hasUpper && !hasDigit                 { return (2, "Fair",   .orange) }
        if hasUpper && hasDigit && hasSpecial     { return (4, "Strong", Color(red: 0.18, green: 0.8, blue: 0.44)) }
        return (3, "Good", Color(red: 0.55, green: 0.76, blue: 0.0))
    }

    @ViewBuilder
    private var strengthBar: some View {
        let (bars, label, color) = strength
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < bars ? color : KlicColor.surfaceRaised)
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.25), value: bars)
            }
            Text(label)
                .font(KlicFont.caption(12))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
                .animation(.easeInOut(duration: 0.25), value: label)
        }
        .padding(.horizontal, 4)
    }
}
