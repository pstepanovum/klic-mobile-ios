import SwiftUI

/// Chat picker used by Forward (§10.9): multi-select over the cached conversations
/// list, with a "Frequent" row on top (§10.4) and a Klic search field.
struct ForwardPickerSheet: View {
    let onSend: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ConversationStore.shared
    @State private var query = ""
    @State private var selectedIds: [String] = []

    private var filtered: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.conversations }
        return store.conversations.filter { title(of: $0).lowercased().contains(q) }
    }

    /// Most-messaged chats first (§10.4), gated by the Suggest Frequent Contacts pref.
    private var frequent: [Conversation] {
        guard FrequentContacts.enabled, query.isEmpty else { return [] }
        return FrequentContacts.topConversations(from: store.conversations)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                KlicSearchField(placeholder: String(localized: "Search chats"), text: $query)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !frequent.isEmpty {
                            sectionHeader(String(localized: "Frequent"))
                            ForEach(frequent) { convo in
                                row(convo)
                            }
                            sectionHeader(String(localized: "All chats"))
                        }
                        ForEach(filtered) { convo in
                            row(convo)
                        }
                    }
                }

                PillButton(
                    title: selectedIds.isEmpty
                        ? String(localized: "Forward")
                        : String(localized: "Forward (\(selectedIds.count))")
                ) {
                    dismiss()
                    onSend(selectedIds)
                }
                .opacity(selectedIds.isEmpty ? 0.4 : 1)
                .disabled(selectedIds.isEmpty)
                .padding(20)
            }
            .padding(.top, 14)
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(KlicColor.textPrimary)
                    }
                }
            }
            .task {
                if store.conversations.isEmpty { await store.refresh() }
            }
        }
        .tint(KlicColor.primary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(KlicFont.caption(12))
            .foregroundStyle(KlicColor.textMuted)
            .textCase(.uppercase)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func row(_ convo: Conversation) -> some View {
        let selected = selectedIds.contains(convo.id)
        return Button {
            if selected {
                selectedIds.removeAll { $0 == convo.id }
            } else {
                selectedIds.append(convo.id)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: avatarUrl(of: convo), name: title(of: convo), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: convo))
                        .font(KlicFont.medium())
                        .foregroundStyle(KlicColor.textPrimary)
                        .lineLimit(1)
                    if convo.type == "GROUP" {
                        Text("Group")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? KlicColor.primary : KlicColor.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(of convo: Conversation) -> String {
        if let t = convo.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        let names = convo.members.map(\.displayName).joined(separator: ", ")
        return names.isEmpty ? String(localized: "Chat") : names
    }

    private func avatarUrl(of convo: Conversation) -> String? {
        convo.avatarUrl ?? (convo.type == "DIRECT" ? convo.members.first?.avatarUrl : nil)
    }
}

extension FrequentContacts {
    /// The most-messaged conversations, for pickers that operate on chats directly.
    @MainActor
    static func topConversations(from conversations: [Conversation], limit: Int = 3) -> [Conversation] {
        guard enabled else { return [] }
        let counts = UserDefaults.standard.dictionary(forKey: "frequent.sendCounts") as? [String: Int] ?? [:]
        guard !counts.isEmpty else { return [] }
        return conversations
            .compactMap { convo -> (Conversation, Int)? in
                guard let count = counts[convo.id], count > 0 else { return nil }
                return (convo, count)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
