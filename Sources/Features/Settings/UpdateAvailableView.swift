import SwiftUI
import Inject

/// §14.7: the "new version available" page, styled like the auth pages — the circle
/// container scaffold with the update artwork in the exposed background, a TikTok
/// Sans title and a red capsule CTA. Dismissible (iOS can't self-install; the CTA
/// opens the GitHub release for the AltStore/TestFlight flow).
struct UpdateAvailableView: View {
    @ObserveInjection var inject
    let release: UpdateChecker.ReleaseInfo
    let currentVersion: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AuthScaffold(artworkName: "UpdateArt", tipFraction: 0.47) {
            VStack(spacing: 0) {
                Text("Update available")
                    .font(KlicFont.expandedMedium(30))
                    .foregroundStyle(AuthStyle.titleColor(colorScheme))

                Text("Klic \(release.version) is ready — you're on \(currentVersion).")
                    .font(KlicFont.body(15))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                if let notes = release.notes {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's new")
                            .font(KlicFont.headline(14))
                            .foregroundStyle(KlicColor.textPrimary)
                        Text(notes)
                            .font(KlicFont.caption(13))
                            .foregroundStyle(KlicColor.textMuted)
                            .lineLimit(6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AuthStyle.fieldFill(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 22)
                }

                PillButton(
                    title: String(localized: "Update now"),
                    fill: AuthStyle.ctaRed,
                    font: KlicFont.expandedMedium(17)
                ) {
                    UIApplication.shared.open(release.url)
                }
                .padding(.top, 24)

                Button(action: onDismiss) {
                    Text("Not now")
                        .font(KlicFont.medium(14))
                        .foregroundStyle(AuthStyle.smallText)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
            .padding(.horizontal, 32)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KlicColor.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(KlicColor.surfaceRaised.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .enableInjection()
    }
}
