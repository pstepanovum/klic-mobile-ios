import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showLastSeen = true
    @State private var savingPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appearanceSection
                    accountSection
                    privacySection
                    VStack(spacing: 6) {
                        KlicLottieView(name: "07", height: 140)
                        Text("Version \(appVersion)")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
        .tint(KlicColor.primary)
        .onAppear { showLastSeen = session.currentUser?.showLastSeen ?? true }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
            HStack(spacing: 10) {
                ForEach(ThemeManager.Scheme.allCases) { scheme in
                    ThemeChip(
                        label: scheme.rawValue,
                        isSelected: themeManager.scheme == scheme
                    ) {
                        themeManager.scheme = scheme
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var accountSection: some View {
        VStack(spacing: 10) {
            if let user = session.currentUser {
                NavigationLink {
                    EditProfileView()
                } label: {
                    HStack(spacing: 14) {
                        AvatarView(url: user.avatarUrl, name: user.displayName, size: 52)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(user.displayName)
                                .font(KlicFont.headline())
                                .foregroundStyle(KlicColor.textPrimary)
                            CopyableUsername(username: user.username)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(18)
                    .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
            }
            PillButton(title: "Log out", fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                session.logout()
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
            Toggle(isOn: $showLastSeen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last seen")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("If turned off, you won't see anyone else's last seen.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .tint(KlicColor.primary)
            .disabled(savingPrivacy)
            .onChange(of: showLastSeen) { _, newValue in
                guard newValue != (session.currentUser?.showLastSeen ?? true) else { return }
                Task { await savePrivacy(newValue) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func savePrivacy(_ value: Bool) async {
        savingPrivacy = true
        defer { savingPrivacy = false }
        if let user = try? await APIClient.shared.updateProfile(showLastSeen: value) {
            session.updateCurrentUser(user)
        } else {
            showLastSeen = session.currentUser?.showLastSeen ?? true   // revert on failure
        }
    }
}

private struct CopyableUsername: View {
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

private struct ThemeChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(KlicFont.medium(14))
                .foregroundStyle(isSelected ? KlicColor.onPrimary : KlicColor.textMuted)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    isSelected ? KlicColor.primary : KlicColor.surfaceRaised,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
