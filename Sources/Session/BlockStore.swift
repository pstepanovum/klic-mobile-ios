import Foundation
import Combine

// MARK: - Blocks store (§16.6)

/// In-memory mirror of GET /blocks — who *I* have blocked. DM chats gate their
/// composer on it synchronously ("You blocked <name>" banner), and the profile
/// block/unblock flows mutate it in place so every open view re-renders at once.
@MainActor
final class BlockStore: ObservableObject {
    static let shared = BlockStore()

    @Published private(set) var blockedIds: Set<String> = []
    private(set) var loaded = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .klicSessionExpired)
            .sink { [weak self] _ in
                self?.blockedIds = []
                self?.loaded = false
            }
            .store(in: &cancellables)
    }

    func isBlocked(_ userId: String) -> Bool { blockedIds.contains(userId) }

    /// Fetch the blocks list; keeps the cached copy on failure.
    func refresh() async {
        if let list = try? await APIClient.shared.blockedUsers() {
            blockedIds = Set(list.map { $0.user.id })
            loaded = true
        }
    }

    /// One fetch per session is enough — the mutators below keep it current.
    func refreshIfNeeded() async {
        guard !loaded else { return }
        await refresh()
    }

    /// POST /blocks, then reflect locally (throws through for the caller's error UI).
    func block(userId: String) async throws {
        _ = try await APIClient.shared.blockUser(userId: userId)
        blockedIds.insert(userId)
        loaded = true
    }

    /// DELETE /blocks/:userId, then reflect locally.
    func unblock(userId: String) async throws {
        try await APIClient.shared.unblockUser(userId: userId)
        blockedIds.remove(userId)
    }
}
