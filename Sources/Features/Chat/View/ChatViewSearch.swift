import SwiftUI

/// §18.4 in-chat message search: a header magnifier opens a search bar with next/prev match
/// navigation, backed by GET /conversations/:id/messages/search (server full-text, so it finds
/// matches beyond the loaded page). Selecting a match reuses jumpToMessageHighlighting (§16.1)
/// to scroll + flash the bubble, fetching older pages back as needed.
extension ChatView {
    func openInChatSearch() {
        withAnimation(.easeOut(duration: 0.2)) { showInChatSearch = true }
    }

    func closeInChatSearch() {
        inChatSearchTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            showInChatSearch = false
        }
        inChatSearchQuery = ""
        inChatMatches = []
        inChatMatchIndex = 0
        inChatSearching = false
    }

    /// Debounce the query, then run a scoped search. Empty query clears the results.
    func scheduleInChatSearch(_ raw: String) {
        inChatSearchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1 else {
            inChatMatches = []
            inChatMatchIndex = 0
            inChatSearching = false
            return
        }
        inChatSearching = true
        inChatSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runInChatSearch(query)
        }
    }

    private func runInChatSearch(_ query: String) async {
        defer { inChatSearching = false }
        do {
            let response = try await APIClient.shared.searchMessagesInConversation(
                conversationId: conversation.id, query: query
            )
            guard !Task.isCancelled else { return }
            inChatMatches = response.results.map(\.messageId)
            inChatMatchIndex = 0
            if let first = inChatMatches.first {
                await jumpToMessageHighlighting(first)
            }
        } catch {
            inChatMatches = []
            inChatMatchIndex = 0
        }
    }

    /// Move the current match cursor by ±1 (wrapping) and jump to it. Matches are newest-first,
    /// so "next" (down chevron) walks toward older messages.
    func stepMatch(_ direction: Int) async {
        guard !inChatMatches.isEmpty else { return }
        let count = inChatMatches.count
        inChatMatchIndex = ((inChatMatchIndex + direction) % count + count) % count
        await jumpToMessageHighlighting(inChatMatches[inChatMatchIndex])
    }
}

/// The inline in-chat search bar shown under the nav bar while searching (§18.4).
struct InChatSearchBar: View {
    @Binding var query: String
    let searching: Bool
    let matchCount: Int
    let matchIndex: Int
    let onPrev: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KlicColor.textMuted)
                TextField(String(localized: "Search this chat"), text: $query)
                    .font(KlicFont.body(15))
                    .foregroundStyle(KlicColor.textPrimary)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(KlicColor.surface, in: Capsule())

            // Match state + next/prev navigation.
            if searching {
                ProgressView().controlSize(.small)
            } else if !trimmed.isEmpty {
                Text(matchCount == 0 ? String(localized: "None") : "\(matchIndex + 1)/\(matchCount)")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .monospacedDigit()
            }

            Button(action: onPrev) {
                Image(systemName: "chevron.up").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(matchCount > 0 ? KlicColor.primary : KlicColor.textMuted)
            .disabled(matchCount == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(matchCount > 0 ? KlicColor.primary : KlicColor.textMuted)
            .disabled(matchCount == 0)

            Button(action: onClose) {
                Text("Cancel")
                    .font(KlicFont.medium(14))
                    .foregroundStyle(KlicColor.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onAppear { focused = true }
    }
}
