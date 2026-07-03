import SwiftUI
import Contacts
import CryptoKit

// MARK: - Contacts sync (§10.4)

/// Uploads SHA-256 hashes of normalized device-contact emails and phone numbers to
/// POST /me/contacts. Raw contact data never leaves the device.
enum ContactsSync {
    private static let enabledKey = "contacts.syncEnabled"
    private static let countKey = "contacts.lastSyncCount"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastSyncCount: Int {
        get { UserDefaults.standard.integer(forKey: countKey) }
        set { UserDefaults.standard.set(newValue, forKey: countKey) }
    }

    enum SyncError: LocalizedError {
        case accessDenied
        var errorDescription: String? {
            String(localized: "Klic doesn't have access to your contacts. Allow it in iOS Settings.")
        }
    }

    /// Fetch, normalize, hash and upload — returns the number of hashes sent.
    @discardableResult
    static func syncNow() async throws -> Int {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { throw SyncError.accessDenied }

        let hashes = try await Task.detached(priority: .utility) { () -> [String] in
            let keys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var identifiers = Set<String>()
            try store.enumerateContacts(with: request) { contact, _ in
                for email in contact.emailAddresses {
                    let normalized = (email.value as String)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if !normalized.isEmpty { identifiers.insert(normalized) }
                }
                for phone in contact.phoneNumbers {
                    let normalized = normalizePhone(phone.value.stringValue)
                    if normalized.count >= 6 { identifiers.insert(normalized) }
                }
            }
            return identifiers.sorted().prefix(5000).map(sha256Hex)
        }.value

        _ = try await APIClient.shared.uploadContactHashes(hashes)
        lastSyncCount = hashes.count
        return hashes.count
    }

    static func deleteSynced() async throws {
        try await APIClient.shared.deleteSyncedContacts()
        lastSyncCount = 0
        enabled = false
    }

    /// Keep digits (and a leading +) only: "+1 (415) 555-0100" → "+14155550100".
    static func normalizePhone(_ raw: String) -> String {
        var result = ""
        for (index, char) in raw.enumerated() {
            if char.isNumber { result.append(char) }
            else if char == "+" && index == 0 { result.append(char) }
        }
        return result
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Frequent contacts (§10.4)

/// Local counter of messages sent per conversation, powering the "Frequent" row atop
/// friend pickers (forward / share / group-create). Never leaves the device.
enum FrequentContacts {
    private static let enabledKey = "frequent.enabled"
    private static let countsKey = "frequent.sendCounts"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func recordSend(conversationId: String) {
        var counts = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        counts[conversationId, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: countsKey)
    }

    private static var counts: [String: Int] {
        UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }

    /// The most-messaged friends, resolved through the cached conversations list.
    @MainActor
    static func topFriends(from friends: [User], limit: Int = 5) -> [User] {
        guard enabled, !friends.isEmpty else { return [] }
        let counts = counts
        guard !counts.isEmpty else { return [] }
        // Map each friend to their DM conversation's send count.
        var scored: [(User, Int)] = []
        for friend in friends {
            guard let dm = ConversationStore.shared.conversations.first(where: { convo in
                convo.type == "DIRECT" && convo.members.contains(where: { $0.id == friend.id })
            }), let count = counts[dm.id], count > 0 else { continue }
            scored.append((friend, count))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

// MARK: - Composer drafts (§10.4)

/// Per-conversation composer drafts, saved when leaving a chat with unsent text.
enum ChatDrafts {
    private static let key = "chat.drafts"

    static func load(_ conversationId: String) -> String {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[conversationId] ?? ""
    }

    static func save(_ conversationId: String, text: String) {
        var drafts = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            drafts.removeValue(forKey: conversationId)
        } else {
            drafts[conversationId] = text
        }
        UserDefaults.standard.set(drafts, forKey: key)
    }

    static func deleteAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Data Settings card

struct DataSettingsCard: View {
    @State private var syncEnabled = ContactsSync.enabled
    @State private var suggestFrequent = FrequentContacts.enabled
    @State private var syncing = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var showDeleteContactsConfirm = false
    @State private var showDeleteDraftsConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Data Settings")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Toggle(isOn: $syncEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Contacts")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text(syncing
                         ? String(localized: "Syncing…")
                         : String(localized: "Uploads anonymous hashes of your contacts to find friends. Names and numbers never leave your device."))
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .tint(KlicColor.primary)
            .disabled(syncing)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .onChange(of: syncEnabled) { _, value in
                guard value != ContactsSync.enabled else { return }
                if value {
                    Task { await sync() }
                } else {
                    ContactsSync.enabled = false
                    statusText = nil
                }
            }

            Divider().padding(.leading, 18).opacity(0.4)

            rowButton(title: String(localized: "Delete Synced Contacts"), destructive: true) {
                showDeleteContactsConfirm = true
            }

            Divider().padding(.leading, 18).opacity(0.4)

            Toggle(isOn: $suggestFrequent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggest Frequent Contacts")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("Shows the people you message most at the top of pickers.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .tint(KlicColor.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .onChange(of: suggestFrequent) { _, value in
                FrequentContacts.enabled = value
            }

            Divider().padding(.leading, 18).opacity(0.4)

            rowButton(title: String(localized: "Delete All Drafts"), destructive: true) {
                showDeleteDraftsConfirm = true
            }

            if let statusText {
                Text(statusText)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.primary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
            if let errorText {
                Text(errorText)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.danger)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .klicSelectionSheet(
            isPresented: $showDeleteContactsConfirm,
            title: String(localized: "Delete synced contacts?"),
            message: String(localized: "Removes every contact hash Klic stored for your account and turns syncing off."),
            options: [KlicSheetOption(id: "delete", label: String(localized: "Delete Synced Contacts"), isDestructive: true)]
        ) { _ in
            Task { await deleteSynced() }
        }
        .klicSelectionSheet(
            isPresented: $showDeleteDraftsConfirm,
            title: String(localized: "Delete all drafts?"),
            message: String(localized: "Clears every unsent message draft saved on this device."),
            options: [KlicSheetOption(id: "delete", label: String(localized: "Delete All Drafts"), isDestructive: true)]
        ) { _ in
            ChatDrafts.deleteAll()
            statusText = String(localized: "Drafts deleted.")
            errorText = nil
        }
    }

    private func rowButton(title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(KlicFont.body())
                    .foregroundStyle(destructive ? KlicColor.danger : KlicColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sync() async {
        syncing = true
        defer { syncing = false }
        errorText = nil
        do {
            let count = try await ContactsSync.syncNow()
            ContactsSync.enabled = true
            statusText = String(localized: "Synced \(count) contact hashes.")
        } catch let e as APIError {
            syncEnabled = false
            errorText = e.userMessage
        } catch {
            syncEnabled = false
            errorText = (error as NSError).localizedDescription
        }
    }

    private func deleteSynced() async {
        errorText = nil
        do {
            try await ContactsSync.deleteSynced()
            syncEnabled = false
            statusText = String(localized: "Synced contacts deleted.")
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't delete synced contacts.")
        }
    }
}
