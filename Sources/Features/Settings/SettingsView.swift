import SwiftUI
import Inject

struct SettingsView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var themeManager: ThemeManager
    /// §12.1: Settings → "Report a problem" opens the target-less report flow.
    @State private var reportTarget: ReportTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeader

                    // My Profile + Appearance
                    mainSection

                    // Notifications + Data and Storage (CALLS.md §8.3/§8.5)
                    dataSection

                    // Updates — own card, visually separated
                    updatesSection

                    // Privacy — own card, navigates to full page
                    privacySection

                    PillButton(title: String(localized: "Log out"), fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                        session.logout()
                    }
                    VStack(spacing: 6) {
                        Text("Version \(appVersion)")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
        .tint(KlicColor.primary)
        .enableInjection()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: Profile header

    private var profileHeader: some View {
        NavigationLink { EditProfileView() } label: {
            VStack(spacing: 10) {
                if let user = session.currentUser {
                    AvatarView(url: user.avatarUrl, name: user.displayName, size: 80)
                    Text(user.displayName)
                        .font(KlicFont.headline())
                        .foregroundStyle(KlicColor.textPrimary)
                    CopyableUsername(username: user.username)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .buttonStyle(.plain)
    }

    // MARK: My Profile + Appearance

    private var mainSection: some View {
        VStack(spacing: 0) {
            NavigationLink { EditProfileView() } label: {
                SettingsRow(icon: "person", title: String(localized: "My Profile"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Saved messages (§14.4): everything the user starred, across chats.
            NavigationLink { SavedMessagesView() } label: {
                SettingsRow(icon: "star", title: String(localized: "Saved messages"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Chat theme lives under Appearance only (§13.6) — no duplicate row here.
            NavigationLink { AppearanceView() } label: {
                SettingsRow(icon: "sun.max", title: String(localized: "Appearance"))
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Notifications + Data and Storage

    private var dataSection: some View {
        VStack(spacing: 0) {
            NavigationLink { NotificationsSettingsView() } label: {
                SettingsRow(icon: "bell", title: String(localized: "Notifications"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink { DataStorageView() } label: {
                SettingsRow(icon: "externaldrive", title: String(localized: "Data and Storage"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Recent Calls (§10.6) — the SAME list the Call tab shows.
            NavigationLink { RecentCallsView() } label: {
                SettingsRow(icon: "phone.arrow.up.right", title: String(localized: "Recent Calls"))
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(spacing: 0) {
            NavigationLink { AppUpdateInfoView(version: appVersion) } label: {
                SettingsRow(icon: "arrow.down.circle", title: String(localized: "Updates"))
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(spacing: 0) {
            NavigationLink { PrivacySecurityView() } label: {
                SettingsRow(icon: "lock", title: String(localized: "Privacy and Security"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // My QR code + scanner (§10.7).
            NavigationLink { QRCodeView() } label: {
                SettingsRow(icon: "qrcode", title: String(localized: "QR Code"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Language (§10.5).
            NavigationLink { LanguageSettingsView() } label: {
                SettingsRow(icon: "globe", title: String(localized: "Language"))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Report a problem (§12.1) — the same report flow, with no target.
            Button { reportTarget = .problem } label: {
                SettingsRow(icon: "exclamationmark.bubble", title: String(localized: "Report a problem"))
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .reportSheet(target: $reportTarget)
    }
}

// MARK: - Appearance page

private struct AppearanceView: View {
    @ObserveInjection var inject
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Chat theme (§12.3)
                VStack(spacing: 0) {
                    NavigationLink { ChatThemeView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "paintbrush")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                                .frame(width: 32, height: 32)
                                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            Text("Chat theme")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                // Night mode
                VStack(spacing: 0) {
                    NavigationLink { AutoNightModeView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "moon")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                                .frame(width: 32, height: 32)
                                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            Text("Auto-Night Mode")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            Text(themeManager.nightMode.rawValue)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }
}

// MARK: - Auto-Night Mode picker

private struct AutoNightModeView: View {
    @ObserveInjection var inject
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(ThemeManager.NightMode.allCases.enumerated()), id: \.element.id) { idx, mode in
                    Button {
                        themeManager.nightMode = mode
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                if let subtitle = mode.subtitle {
                                    Text(subtitle)
                                        .font(KlicFont.caption(12))
                                        .foregroundStyle(KlicColor.textMuted)
                                }
                            }
                            Spacer()
                            if themeManager.nightMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(KlicColor.primary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < ThemeManager.NightMode.allCases.count - 1 {
                        Divider().padding(.leading, 20).opacity(0.4)
                    }
                }
            }
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Auto-Night Mode")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }
}

// MARK: - Updates info page

/// §20.2: a REAL update page — hits the public GitHub "latest release" on appear (throttled)
/// and on demand via "Check for updates", then reflects the live state: checking / up to
/// date / update available (version + notes + a CTA to the AltStore/TestFlight release) /
/// offline / rate-limited / failed. iOS can't self-install IPAs, so the CTA opens the flow.
private struct AppUpdateInfoView: View {
    let version: String
    @StateObject private var checker = UpdateChecker.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusCard

                // Info rows
                VStack(spacing: 0) {
                    infoRow(label: String(localized: "Version"), value: version)
                    Divider().padding(.leading, 20).opacity(0.4)
                    infoRow(label: String(localized: "Platform"), value: "iOS")
                    Divider().padding(.leading, 20).opacity(0.4)
                    infoRow(label: String(localized: "Distribution"), value: "AltStore / TestFlight")
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                if let release = availableRelease, let notes = release.notes {
                    whatsNewCard(notes: notes)
                }

                ctaButton

                Text("Klic checks for new releases automatically and shows an update page when one is available. iOS updates install via AltStore or TestFlight.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { checker.checkOnAppear() }
    }

    private var availableRelease: UpdateChecker.ReleaseInfo? {
        if case let .updateAvailable(release) = checker.status { return release }
        return nil
    }

    // MARK: State card

    private var statusCard: some View {
        VStack(spacing: 12) {
            KlicLottieView(name: "07", height: 140)
            Image(systemName: statusIcon)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(statusTint)
            Text(availableRelease.map { "Klic \($0.version)" } ?? "Klic \(version)")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
            Text(statusSubtitle)
                .font(KlicFont.caption())
                .foregroundStyle(statusIsError ? KlicColor.danger : KlicColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func whatsNewCard(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's new")
                .font(KlicFont.headline(14))
                .foregroundStyle(KlicColor.textPrimary)
            Text(notes)
                .font(KlicFont.caption(13))
                .foregroundStyle(KlicColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var ctaButton: some View {
        if let release = availableRelease {
            PillButton(
                title: String(localized: "Update now"),
                fill: KlicColor.danger,
                font: KlicFont.expandedMedium(17)
            ) {
                UIApplication.shared.open(release.url)
            }
        } else {
            PillButton(
                title: String(localized: "Check for updates"),
                fill: KlicColor.surfaceRaised,
                textColor: KlicColor.textPrimary,
                isLoading: checker.status == .checking
            ) {
                checker.checkNow(force: true)
            }
        }
    }

    // MARK: State mapping

    private var statusIcon: String {
        switch checker.status {
        case .updateAvailable: return "arrow.down.circle.fill"
        case .offline:         return "wifi.slash"
        case .rateLimited:     return "clock.badge.exclamationmark"
        case .failed:          return "exclamationmark.triangle"
        case .checking:        return "arrow.triangle.2.circlepath"
        case .upToDate, .idle: return "checkmark.seal"
        }
    }

    private var statusTint: Color {
        switch checker.status {
        case .updateAvailable:            return KlicColor.danger
        case .offline, .rateLimited, .failed: return KlicColor.textMuted
        default:                          return KlicColor.primary
        }
    }

    private var statusIsError: Bool {
        switch checker.status {
        case .offline, .rateLimited, .failed: return true
        default: return false
        }
    }

    private var statusSubtitle: String {
        switch checker.status {
        case .checking:
            return String(localized: "Checking for updates…")
        case let .updateAvailable(release):
            return String(localized: "Version \(release.version) is available")
        case .upToDate:
            return String(localized: "You're on the latest version")
        case .offline:
            return String(localized: "You're offline. Connect and try again.")
        case .rateLimited:
            return String(localized: "Too many checks — please try again later.")
        case .failed:
            return String(localized: "Couldn't check for updates. Please try again.")
        case .idle:
            return String(localized: "You're on the latest version")
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Text(value)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Shared helpers

private struct SettingsRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - NightMode subtitles

private extension ThemeManager.NightMode {
    var subtitle: String? {
        switch self {
        case .system:    return String(localized: "Follows your iOS appearance setting")
        case .disabled:  return String(localized: "Always light")
        case .scheduled: return String(localized: "Set custom day / night hours")
        case .automatic: return String(localized: "Based on ambient light")
        }
    }
}
