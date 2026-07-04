import SwiftUI
import AVFoundation
import Inject

struct RootView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var callKit = CallKitManager.shared
    @StateObject private var appLock = AppLockManager.shared
    @StateObject private var friendLinks = FriendLinkRouter.shared
    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var didGetStarted = false
    @State private var selectedTab: RootTab = .chats

    private enum RootTab: Hashable {
        case chats, friends, call, settings
    }

    /// Ask for mic + camera the moment the user is signed in — never mid-call. Asking when LiveKit
    /// first touches the devices is jarring and, for a callee, too late: an un-granted mic means the
    /// peer hears silence for the whole call. requestAccess only prompts when status is
    /// .notDetermined, so this is a no-op once the user has answered the prompts.
    private func requestCallPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    /// The call the fullScreenCover presents: hidden while minimized (the floating overlay
    /// takes over) without touching `activeCall` — dismissing the cover must never tear the
    /// live call down. The setter ignores dismissals for the same reason.
    private var presentedCall: Binding<CallKitManager.ActiveCall?> {
        Binding(
            get: { callKit.callMinimized ? nil : callKit.activeCall },
            set: { _ in }
        )
    }

    var body: some View {
        ZStack {
            Group {
                if session.isAuthenticated {
                    TabView(selection: $selectedTab) {
                        ConversationsView()
                            .tabItem {
                                Image("ic_line_message_3").renderingMode(.template)
                                Text("Chats")
                            }
                            .tag(RootTab.chats)
                        FriendsView()
                            .tabItem {
                                Image(KlicIcon.user.line).renderingMode(.template)
                                Text("Friends")
                            }
                            .tag(RootTab.friends)
                        CallDialView()
                            .tabItem {
                                Image(KlicIcon.phone.line).renderingMode(.template)
                                Text("Call")
                            }
                            .tag(RootTab.call)
                        SettingsView()
                            .tabItem {
                                Image(KlicIcon.settings.line).renderingMode(.template)
                                Text("Settings")
                            }
                            .tag(RootTab.settings)
                    }
                    .tint(KlicColor.primary)
                    .onAppear { requestCallPermissions() }
                    // §13.8: an incoming friend link jumps to the Friends tab, where
                    // FriendsView opens the add-friend flow prefilled.
                    .onReceive(friendLinks.$pendingUsername) { username in
                        if username != nil { selectedTab = .friends }
                    }
                } else if didGetStarted {
                    AuthView()
                        .transition(.identity)
                } else {
                    WelcomeView { didGetStarted = true }
                        .transition(.identity)
                }
            }
            // §11.3: while locked, the app content itself is fully blurred (the lock
            // overlay adds a material wash on top — nothing behind is readable).
            .blur(radius: appLock.isLocked && session.isAuthenticated ? 28 : 0)
            .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)

            // Floating in-call overlay while minimized, above all navigation. Disappears on
            // its own when the call ends (activeCall goes nil → callMinimized resets).
            if callKit.callMinimized, let call = callKit.activeCall {
                MinimizedCallOverlay(call: call)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .zIndex(1)
            }

            // App lock overlay (§10.4). Sits above the tabs but BELOW the call
            // fullScreenCover — incoming CallKit call UI bypasses the lock (UI-only;
            // call plumbing untouched).
            if appLock.isLocked, session.isAuthenticated {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.3), value: callKit.callMinimized)
        .fullScreenCover(item: presentedCall) { call in
            CallView(call: call)
        }
        // §14.7: a newer GitHub release → dismissible update page (auth styling).
        // Checked on launch + foreground, throttled to once per 6h by the checker.
        .fullScreenCover(item: $updateChecker.available) { release in
            UpdateAvailableView(
                release: release,
                currentVersion: updateChecker.currentVersion,
                onDismiss: { updateChecker.dismiss() }
            )
        }
        .task { updateChecker.checkIfDue() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updateChecker.checkIfDue() }
        }
        .enableInjection()
    }
}
