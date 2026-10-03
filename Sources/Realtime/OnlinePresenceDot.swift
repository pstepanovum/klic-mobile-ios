import SwiftUI

/// Green "online" dot overlaid on an avatar. Observes SocketService on its own so a
/// presence/typing event re-renders only these tiny dots, not the list or row hosting
/// them (rows previously observed SocketService and re-rendered on every socket event).
struct OnlinePresenceDot: View {
    /// nil → never shown (e.g. group conversations).
    let userId: String?
    @ObservedObject private var socket = SocketService.shared

    var body: some View {
        if let userId, socket.presence[userId]?.online == true {
            Circle().fill(.green).frame(width: 14, height: 14)
                .overlay(Circle().stroke(KlicColor.background, lineWidth: 2))
        }
    }
}
