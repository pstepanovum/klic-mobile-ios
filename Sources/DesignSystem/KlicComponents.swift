import SwiftUI

/// Fully-rounded, flat primary button. No shadows, no strokes (per design rules).
struct PillButton: View {
    let title: String
    var fill: Color = KlicColor.primary
    var textColor: Color = KlicColor.onPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KlicFont.headline())
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Circular in-call control (mic / camera / end). Flat, fully rounded.
struct CircleControl: View {
    let icon: KlicIcon
    var fill: Color = KlicColor.surfaceRaised
    var iconColor: Color = KlicColor.textPrimary
    var diameter: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 26, color: iconColor)
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Checkbox with an inline "I agree to the Privacy Policy" label.
struct KlicCheckbox: View {
    @Binding var isChecked: Bool
    let onPrivacyTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isChecked.toggle() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isChecked ? KlicColor.primary : Color.clear)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isChecked ? KlicColor.primary : KlicColor.textMuted.opacity(0.45),
                            lineWidth: 1.5
                        )
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(KlicColor.onPrimary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                Text("I agree to the")
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textMuted)
                Button("Privacy Policy") { onPrivacyTap() }
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.primary)
            }

            Spacer()
        }
    }
}

/// Constrains width to `max` and centers within parent — keeps content readable on large screens.
extension View {
    func adaptiveWidth(_ max: CGFloat = 680) -> some View {
        self
            .frame(maxWidth: max)
            .frame(maxWidth: .infinity)
    }
}

/// Fully-rounded search bar matching the Login-page inputs (§9.8) — used everywhere
/// a list is filtered (chats, members, messages) instead of the stock searchable bar.
struct KlicSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KlicColor.textMuted)
            TextField(placeholder, text: $text)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(KlicColor.textMuted.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(KlicColor.surface, in: Capsule())
    }
}

/// Username chip with tap-to-copy feedback, shared by Settings and profile pages.
struct CopyableUsername: View {
    let username: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = username
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Text("@\(username)")
                    .font(KlicFont.caption())
                    .foregroundStyle(copied ? KlicColor.primary : KlicColor.textMuted)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? KlicColor.primary : KlicColor.textMuted.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                copied ? KlicColor.primary.opacity(0.1) : KlicColor.surfaceRaised,
                in: Capsule()
            )
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
    }
}

/// Flat text field on a rounded surface — no border, no outline.
struct KlicTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(KlicFont.body())
        .foregroundStyle(KlicColor.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(KlicColor.surface, in: Capsule())
    }
}
