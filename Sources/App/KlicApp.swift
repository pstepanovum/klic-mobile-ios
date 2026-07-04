import SwiftUI
import UserNotifications
import Intents
import GoogleSignIn

@main
struct KlicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = AppSession()
    @StateObject private var themeManager = ThemeManager()

    init() {
        configureNavigationBar()
        configureTabBar()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Simulator-only layout harness for the call screens (see CallLayoutDemoView);
            // inert unless the app is launched with the -callLayoutDemo argument.
            if CallLayoutDemoView.isRequested {
                CallLayoutDemoView()
                    .preferredColorScheme(themeManager.colorScheme)
                    .tint(KlicColor.primary)
            } else {
                appRoot
            }
            #else
            appRoot
            #endif
        }
    }

    private var appRoot: some View {
        RootView()
            .environmentObject(session)
            .environmentObject(themeManager)
            .preferredColorScheme(themeManager.colorScheme)
            .tint(KlicColor.primary)
            .onAppear { session.bootstrap() }
            .onChange(of: scenePhase) { _, phase in
                // App lock (§10.4): lock on background/foreground per the auto-lock pref.
                AppLockManager.shared.handleScenePhase(phase)
                if phase == .active {
                    // Clear the app-icon badge + delivered banners when the user is back in.
                    UNUserNotificationCenter.current().setBadgeCount(0)
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    if CallKitManager.shared.activeCall == nil {
                        CallActivityController.end()
                    }
                }
            }
            // Siri / CarPlay / Phone-app Recents call-back → resolve the contact and dial.
            // The legacy audio/video intents cover older routing (still sent by some paths).
            .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                CallIntents.startCall(from: activity)
            }
            .onContinueUserActivity("INStartAudioCallIntent") { activity in
                CallIntents.startCall(from: activity)
            }
            .onContinueUserActivity("INStartVideoCallIntent") { activity in
                CallIntents.startCall(from: activity)
            }
            // Friend links (§13.8) + Google sign-in callback for email linking (§12.2).
            .onOpenURL { url in
                if FriendLinkRouter.shared.handle(url) { return }
                _ = GIDSignIn.sharedInstance.handle(url)
            }
            // Universal links (§13.8): /u/* and /add/* → the add-friend flow.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    FriendLinkRouter.shared.handle(url)
                }
            }
    }

    private func configureNavigationBar() {
        UINavigationBar.appearance().tintColor = UIColor(KlicColor.primary)
        // §13.2: top-level page titles (Chats / Friends / Call / Settings — the large
        // navigation titles) render in TikTok Sans 24pt Expanded Regular. Only the
        // large-title font changes; inline titles on sub-pages keep the system face.
        if let titleFont = UIFont(name: "TikTokSans24ptExpanded-Regular", size: 34) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: titleFont]
        }
    }

    private func configureTabBar() {
        let darkSurface  = UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)
        let lightSurface = UIColor.white
        let adaptiveBg   = UIColor { $0.userInterfaceStyle == .dark ? darkSurface : lightSurface }

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = adaptiveBg

        UITabBar.appearance().standardAppearance   = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
