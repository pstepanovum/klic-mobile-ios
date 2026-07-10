import SwiftUI
import Inject

struct TermsOfServiceView: View {
    @ObserveInjection var inject
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, body: String)] = [
        (
            "Acceptance of terms",
            "By creating a Klic account or using the app you agree to these terms. If you don't agree, please don't use Klic."
        ),
        (
            "User conduct",
            "You are responsible for the content you share. Klic has ZERO TOLERANCE for objectionable content and abusive users. The following are strictly prohibited:\n\n• Harassment, bullying, or threats against any person\n• Hate speech or discrimination\n• Any sexual content involving minors\n• Content that promotes or glorifies violence\n• Spam or deceptive behavior\n\nUse the in-app tools to report messages or users and to block anyone you don't want to hear from."
        ),
        (
            "Moderation",
            "We review every report. Content that violates these terms is removed and abusive users are ejected within 24 hours of a report."
        ),
        (
            "Account termination",
            "Violating these terms may result in removal of your content and suspension or permanent termination of your account, without prior notice."
        ),
        (
            "Your content",
            "You own the content you share on Klic. You grant Klic a limited license to transmit and store it solely to provide the service — delivering your messages, calls, and media to their recipients."
        ),
        (
            "Disclaimer & liability",
            "Klic is provided \"as is\", without warranties of any kind. To the maximum extent permitted by law, Klic is not liable for indirect or consequential damages arising from your use of the app."
        ),
        (
            "Contact",
            "Questions? Reach us at privacy@klic.pstepanov.dev"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(KlicFont.headline())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text(section.body)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("Effective date: July 9, 2026")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.top, 4)
                }
                .padding(24)
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Terms of Service")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(KlicColor.primary)
                }
            }
        }
        .enableInjection()
    }
}
