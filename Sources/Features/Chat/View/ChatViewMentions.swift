import SwiftUI

/// @-mention suggestions in group composers (CALLS.md §9.5): typing "@" surfaces a
/// strip above the input with @all + members matching the typed prefix; tapping
/// inserts "@DisplayName " at the token. Bubbles highlight member mentions the same
/// way @all is highlighted (client-side match on current member names).
extension ChatView {
    struct MentionCandidate: Identifiable {
        let id: String            // userId, or "all"
        let displayName: String
        let avatarUrl: String?
        var isAll: Bool { id == "all" }
    }

    /// The trailing "@prefix" token being typed, or nil when no suggestions apply.
    /// Matches an "@" that starts the draft or follows whitespace, with no newline
    /// after it — the same shape the server's push gate accepts.
    var mentionQuery: String? {
        guard !isDirect else { return nil }
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex != draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace else { return nil }
        }
        let query = String(draft[draft.index(after: atIndex)...])
        guard query.count <= 32, !query.contains(where: \.isNewline) else { return nil }
        return query
    }

    var mentionSuggestions: [MentionCandidate] {
        guard let query = mentionQuery?.lowercased() else { return [] }
        var out: [MentionCandidate] = []
        if query.isEmpty || "all".hasPrefix(query) {
            out.append(MentionCandidate(id: "all", displayName: "all", avatarUrl: nil))
        }
        out += memberTargets
            .filter { $0.id != myId }
            .filter {
                query.isEmpty
                    || $0.displayName.lowercased().hasPrefix(query)
                    || $0.username.lowercased().hasPrefix(query)
            }
            .map { MentionCandidate(id: $0.id, displayName: $0.displayName, avatarUrl: $0.avatarUrl) }
        return out
    }

    /// Names whose "@Name" occurrences get the accent treatment in bubbles.
    var mentionHighlightNames: [String] {
        guard !isDirect else { return [] }
        return memberTargets.map(\.displayName)
    }

    /// Replace the "@prefix" token under construction with the picked mention.
    func insertMention(_ candidate: MentionCandidate) {
        guard let atIndex = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<atIndex]) + "@\(candidate.displayName) "
        isComposerFocused = true
    }
}

/// Horizontal chip strip shown directly above the composer while an @-token is typed.
struct MentionSuggestionStrip: View {
    let suggestions: [ChatView.MentionCandidate]
    let onPick: (ChatView.MentionCandidate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { candidate in
                    Button {
                        onPick(candidate)
                    } label: {
                        HStack(spacing: 6) {
                            if candidate.isAll {
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(KlicColor.primary)
                            } else {
                                AvatarView(url: candidate.avatarUrl, name: candidate.displayName, size: 22)
                            }
                            Text("@\(candidate.displayName)")
                                .font(KlicFont.medium(13))
                                .foregroundStyle(KlicColor.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(KlicColor.surfaceRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.clear)
    }
}
