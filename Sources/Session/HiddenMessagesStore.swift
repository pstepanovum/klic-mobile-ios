import Foundation

// MARK: - Hidden messages store (§12.1)

/// Device-local "Hide" filter for objectionable content: message ids hidden via the
/// long-press menu disappear from the chat rendering on THIS device only — no server
/// call, nothing changes for the sender or other members. Settings → Privacy and
/// Security → "Reset hidden messages" clears the whole set, so every open chat
/// re-renders the messages at once.
@MainActor
final class HiddenMessagesStore: ObservableObject {
    static let shared = HiddenMessagesStore()

    private static let key = "chat.hiddenMessageIds"

    @Published private(set) var ids: Set<String>

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    var count: Int { ids.count }

    func isHidden(_ messageId: String) -> Bool { ids.contains(messageId) }

    func hide(_ messageId: String) {
        ids.insert(messageId)
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }

    /// Settings → "Reset hidden messages": every hidden message shows again.
    func reset() {
        ids = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
