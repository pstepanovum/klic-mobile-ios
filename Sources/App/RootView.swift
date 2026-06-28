import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var callKit = CallKitManager.shared
    @State private var didGetStarted = false

    var body: some View {
        Group {
            if session.isAuthenticated {
                TabView {
                    ConversationsView()
                        .tabItem {
                            Image("ic_line_message_3").renderingMode(.template)
                            Text("Chats")
                        }
                    FriendsView()
                        .tabItem {
                            Image(KlicIcon.user.line).renderingMode(.template)
                            Text("Friends")
                        }
                    CallDialView()
                        .tabItem {
                            Image(KlicIcon.phone.line).renderingMode(.template)
                            Text("Call")
                        }
                    SettingsView()
                        .tabItem {
                            Image(KlicIcon.settings.line).renderingMode(.template)
                            Text("Settings")
                        }
                }
                .tint(KlicColor.primary)
            } else if didGetStarted {
                AuthView()
            } else {
                WelcomeView { withAnimation { didGetStarted = true } }
            }
        }
        .fullScreenCover(item: $callKit.activeCall) { call in
            CallView(call: call)
        }
    }
}
