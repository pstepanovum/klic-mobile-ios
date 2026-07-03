import SwiftUI

/// Settings → Language (§10.5): System default / English / Русский / 中文.
/// Applies an AppleLanguages override and prompts for a relaunch (iOS caches the
/// launch language per process).
struct LanguageSettingsView: View {
    private static let overrideKey = "AppleLanguages"

    private struct Option: Identifiable {
        let id: String          // "" = system default
        let label: String
    }

    private let options: [Option] = [
        Option(id: "", label: String(localized: "System default")),
        Option(id: "en", label: String(localized: "English")),
        Option(id: "ru", label: String(localized: "Русский")),
        Option(id: "zh-Hans", label: String(localized: "中文 (简体)")),
    ]

    @State private var selected: String = {
        // An explicit override is a single-element AppleLanguages array we set below.
        guard UserDefaults.standard.object(forKey: "klic.languageOverride") != nil else { return "" }
        return UserDefaults.standard.string(forKey: "klic.languageOverride") ?? ""
    }()
    @State private var showRelaunchPrompt = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        Button {
                            apply(option.id)
                        } label: {
                            HStack {
                                Text(option.label)
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                Spacer()
                                if selected == option.id {
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
                        if index < options.count - 1 {
                            Divider().padding(.leading, 20).opacity(0.4)
                        }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                Text("Changing the language takes effect after Klic restarts.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .alert(String(localized: "Restart Klic"), isPresented: $showRelaunchPrompt) {
            Button(String(localized: "Later"), role: .cancel) {}
            Button(String(localized: "Quit Now"), role: .destructive) {
                // A clean exit; the user relaunches into the new language.
                exit(0)
            }
        } message: {
            Text("Klic needs to restart to apply the new language.")
        }
    }

    private func apply(_ code: String) {
        selected = code
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.overrideKey)
            UserDefaults.standard.removeObject(forKey: "klic.languageOverride")
        } else {
            UserDefaults.standard.set([code], forKey: Self.overrideKey)
            UserDefaults.standard.set(code, forKey: "klic.languageOverride")
        }
        showRelaunchPrompt = true
    }
}
