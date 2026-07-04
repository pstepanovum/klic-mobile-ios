import SwiftUI
import UIKit
import Inject

/// Fully-rounded capsule input used on the Login / Sign Up pages. Distinct from the
/// generic `KlicTextField` — this one matches the Figma mock's specific fill/hint
/// colors and fixed ~44pt height, with an optional fixed leading glyph (the "@" on
/// the username field).
struct AuthTextField: View {
    @ObserveInjection var inject

    var prefix: String? = nil
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: UITextContentType? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var revealSecure = false

    var body: some View {
        HStack(spacing: 6) {
            if let prefix {
                Text(prefix)
                    .font(KlicFont.medium(16))
                    .foregroundStyle(AuthStyle.fieldHint)
            }

            Group {
                if isSecure && !revealSecure {
                    SecureField("", text: $text, prompt: placeholderText)
                } else {
                    TextField("", text: $text, prompt: placeholderText)
                }
            }
            .font(KlicFont.body(16))
            .foregroundStyle(KlicColor.textPrimary)
            .tint(AuthStyle.ctaRed)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(contentType)

            if isSecure {
                Button {
                    revealSecure.toggle()
                } label: {
                    Image(revealSecure ? "IconEyeClosed" : "IconEyeOpen")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        // Matches PillButton's rendered height (16pt vertical padding around
        // its ~17pt Expanded-Medium label) so inputs and the CTA read as the
        // same pill height in a stack.
        .frame(height: 52)
        .background(AuthStyle.fieldFill(colorScheme), in: Capsule())
        .enableInjection()
    }

    private var placeholderText: Text {
        Text(placeholder)
            .font(KlicFont.body(14))
            .foregroundColor(AuthStyle.fieldHint)
    }
}
