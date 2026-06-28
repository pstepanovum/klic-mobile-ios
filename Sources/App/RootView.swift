import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    var body: some View {
        Group {
            if session.isAuthenticated {
                TabView {
                    ConversationsView()
                        .tabItem { Label("Chats", systemImage: KlicIcon.message.symbol) }
                    FriendsView()
                        .tabItem { Label("Friends", systemImage: KlicIcon.user.symbol) }
                }
            } else {
                AuthView()
            }
        }
        // Incoming call → present the call screen over whatever is on top.
        .fullScreenCover(item: $socket.incomingCall) { invite in
            CallView(
                session: CallSession(
                    callId: invite.id, roomName: invite.roomName, livekitUrl: invite.livekitUrl,
                    token: "", kind: invite.kind
                ),
                peerName: invite.fromDisplayName
            )
        }
    }
}
