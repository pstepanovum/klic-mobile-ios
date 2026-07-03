import SwiftUI
import SafariServices
import WebKit

/// "Open links in" (§10.4): Klic's in-app browser (SFSafariViewController) or Safari,
/// plus a "Don't open links in-app" override. Every link tap in chat routes through
/// `LinkOpener.open`.
enum LinkOpenPrefs {
    enum Browser: String, CaseIterable, Identifiable {
        case inApp
        case safari

        var id: String { rawValue }
        var label: String {
            switch self {
            case .inApp:  return String(localized: "Klic (in-app)")
            case .safari: return String(localized: "Safari")
            }
        }
    }

    private static let browserKey = "links.browser"
    private static let forceExternalKey = "links.forceExternal"

    static var browser: Browser {
        get { UserDefaults.standard.string(forKey: browserKey).flatMap(Browser.init) ?? .inApp }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: browserKey) }
    }

    /// "Don't open links in-app" — forces external Safari even for previews.
    static var forceExternal: Bool {
        get { UserDefaults.standard.bool(forKey: forceExternalKey) }
        set { UserDefaults.standard.set(newValue, forKey: forceExternalKey) }
    }
}

enum LinkOpener {
    /// Route a tapped link per the user's "Open links in" preference (§10.4).
    @MainActor
    static func open(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        if LinkOpenPrefs.browser == .inApp, !LinkOpenPrefs.forceExternal {
            guard let presenter = topViewController() else {
                UIApplication.shared.open(url)
                return
            }
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = UIColor(KlicColor.primary)
            presenter.present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Clear the in-app browser's website data store (cookies, caches, local storage).
    static func clearCookies() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - Settings card

/// The "Open links in" card on the Privacy and Security page: browser picker
/// (KlicSelectionSheet), "Clear cookies" and the "Don't open links in-app" toggle.
struct OpenLinksCard: View {
    @State private var browser = LinkOpenPrefs.browser
    @State private var forceExternal = LinkOpenPrefs.forceExternal
    @State private var showBrowserSheet = false
    @State private var showClearConfirm = false
    @State private var clearedToast = false

    var body: some View {
        VStack(spacing: 0) {
            Button { showBrowserSheet = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "safari")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(KlicColor.primary)
                        .frame(width: 32, height: 32)
                        .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text("Open links in")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text(browser.label)
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            Button { showClearConfirm = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(KlicColor.primary)
                        .frame(width: 32, height: 32)
                        .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text(clearedToast ? String(localized: "Cookies cleared") : String(localized: "Clear cookies"))
                        .font(KlicFont.body())
                        .foregroundStyle(clearedToast ? KlicColor.primary : KlicColor.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            Toggle(isOn: $forceExternal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Don't open links in-app")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("Always use Safari, including link previews.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .tint(KlicColor.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .onChange(of: forceExternal) { _, value in
                LinkOpenPrefs.forceExternal = value
            }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .klicSelectionSheet(
            isPresented: $showBrowserSheet,
            title: String(localized: "Open links in"),
            options: LinkOpenPrefs.Browser.allCases.map { KlicSheetOption(id: $0.rawValue, label: $0.label) },
            selectedId: browser.rawValue
        ) { option in
            guard let picked = LinkOpenPrefs.Browser(rawValue: option.id) else { return }
            browser = picked
            LinkOpenPrefs.browser = picked
        }
        .klicSelectionSheet(
            isPresented: $showClearConfirm,
            title: String(localized: "Clear cookies?"),
            message: String(localized: "Removes cookies and site data stored by the in-app browser."),
            options: [KlicSheetOption(id: "clear", label: String(localized: "Clear cookies"), isDestructive: true)]
        ) { _ in
            Task {
                await LinkOpener.clearCookies()
                withAnimation { clearedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { clearedToast = false }
                }
            }
        }
    }
}
