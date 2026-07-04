import SwiftUI
import Inject

/// §14.3: the "Encryption" information page reached from the lock row on DM and
/// group info pages — Klic-styled, with a "Learn more" link.
struct EncryptionInfoView: View {
    @ObserveInjection var inject

    private static let learnMoreURL = URL(string: "https://klic.pstepanov.dev")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(KlicColor.primary)
                        .frame(width: 104, height: 104)
                        .background(KlicColor.primary.opacity(0.12), in: Circle())
                        .padding(.top, 12)

                    Text("Your chats and calls are private")
                        .font(KlicFont.headline(22))
                        .foregroundStyle(KlicColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("End-to-end encryption keeps your personal messages and calls between you and the people you choose. No one outside — not even Klic — can read, listen to, or share them.")
                        .font(KlicFont.body(15))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 0) {
                    Text("This includes your:")
                        .font(KlicFont.headline(15))
                        .foregroundStyle(KlicColor.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    coveredRow(icon: "text.bubble.fill", title: String(localized: "Text and voice messages"))
                    coveredRow(icon: "phone.fill", title: String(localized: "Audio and video calls"))
                    coveredRow(icon: "photo.fill", title: String(localized: "Photos, videos and documents"))
                    Color.clear.frame(height: 10)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                Button {
                    UIApplication.shared.open(Self.learnMoreURL)
                } label: {
                    HStack(spacing: 6) {
                        Text("Learn more")
                            .font(KlicFont.medium(15))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(KlicColor.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }

    private func coveredRow(icon: String, title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(KlicFont.body(15))
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

// MARK: - Theme + encryption rows (§14.3)

/// The chat-personalization card shared by the DM profile page and the group info
/// page: "Chat theme" (per-DM local override, or the group's shared theme —
/// admin-only there) and the "Encryption" info row.
struct ChatThemeEncryptionRows: View {
    let conversationId: String
    let isGroup: Bool
    /// Group theme editing is admin-only; DMs always allow the local override.
    var canEditTheme: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if canEditTheme {
                NavigationLink {
                    ConversationThemeView(conversationId: conversationId, isGroup: isGroup)
                } label: {
                    row(icon: "paintbrush", title: String(localized: "Chat theme"))
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 64).opacity(0.4)
            }

            NavigationLink {
                EncryptionInfoView()
            } label: {
                row(icon: "lock", title: String(localized: "Encryption"))
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(icon: String, title: String) -> some View {
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
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
