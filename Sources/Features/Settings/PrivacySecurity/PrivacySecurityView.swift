import SwiftUI

/// Settings → Privacy and Security (§10.4/§11.6): the Privacy card (visibility
/// selectors, silence unknown callers, read receipts), plus rounded cards for
/// Blocked Users, Passcode & Face ID, Passkeys, Open links in, Data Settings and
/// account deletion.
struct PrivacySecurityView: View {
    @EnvironmentObject var session: AppSession

    // Privacy controls (§11.6).
    @State private var visibilities: [PrivacyField: KlicVisibility] = [:]
    @State private var activeField: PrivacyField?
    @State private var silenceUnknownCallers = false
    @State private var readReceipts = true
    @State private var savingPrivacy = false
    @State private var privacyError: String?
    /// Guards the toggle onChange handlers while state is programmatically synced.
    @State private var syncingToggles = false

    // Auto-delete account (§10.4).
    @State private var deleteIfAwayMonths: Int?
    @State private var showAwaySheet = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteTypeConfirm = false
    @State private var typedUsername = ""
    @State private var deleting = false
    @State private var accountError: String?

    private static let awayOptions = [1, 3, 6, 12, 18, 24]

    /// The §11.6 visibility rows — id doubles as the PATCH /me field name.
    enum PrivacyField: String, CaseIterable, Identifiable {
        case lastSeen = "lastSeenVisibility"
        case about = "aboutVisibility"
        case avatar = "avatarVisibility"
        case links = "linksVisibility"
        case groups = "groupsVisibility"
        case status = "statusVisibility"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .lastSeen: return String(localized: "Last seen & online")
            case .about:    return String(localized: "About")
            case .avatar:   return String(localized: "Profile picture")
            case .links:    return String(localized: "Links")
            case .groups:   return String(localized: "Groups")
            case .status:   return String(localized: "Status")
            }
        }
        var icon: String {
            switch self {
            case .lastSeen: return "clock"
            case .about:    return "text.quote"
            case .avatar:   return "person.crop.circle"
            case .links:    return "link"
            case .groups:   return "person.3"
            case .status:   return "message.badge"
            }
        }
        var sheetMessage: String {
            switch self {
            case .lastSeen: return String(localized: "Who can see when you were last online.")
            case .about:    return String(localized: "Who can see your About.")
            case .avatar:   return String(localized: "Who can see your profile picture.")
            case .links:    return String(localized: "Who can see your links.")
            case .groups:   return String(localized: "Who can add you to groups.")
            case .status:   return String(localized: "Who can see your status.")
            }
        }
        /// Contract defaults: EVERYBODY everywhere, FRIENDS for last seen.
        var defaultVisibility: KlicVisibility { self == .lastSeen ? .friends : .everybody }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Privacy (§11.6) — replaces the old "Last seen" toggle.
                privacyCard

                // Blocked users + app lock + passkeys
                VStack(spacing: 0) {
                    NavigationLink { BlockedUsersView() } label: {
                        PrivacyRow(icon: "hand.raised", title: String(localized: "Blocked Users"))
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 64).opacity(0.4)

                    NavigationLink { PasscodeSettingsView() } label: {
                        PrivacyRow(icon: "faceid", title: String(localized: "Passcode & Face ID"))
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 64).opacity(0.4)

                    NavigationLink { PasskeysView() } label: {
                        PrivacyRow(icon: "person.badge.key", title: String(localized: "Passkeys"))
                    }
                    .buttonStyle(.plain)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                // Open links in
                OpenLinksCard()

                // Data settings
                DataSettingsCard()

                // Automatically delete my account
                VStack(alignment: .leading, spacing: 0) {
                    Text("Automatically delete my account")
                        .font(KlicFont.headline(17))
                        .foregroundStyle(KlicColor.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    Button { showAwaySheet = true } label: {
                        HStack {
                            Text("If away for")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            Text(awayLabel(deleteIfAwayMonths))
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 18).opacity(0.4)

                    Button { showDeleteConfirm = true } label: {
                        HStack {
                            Text(deleting ? String(localized: "Deleting…") : String(localized: "Delete Account Now"))
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.danger)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(deleting)

                    if let accountError {
                        Text(accountError)
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.danger)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Privacy and Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { syncPrivacy(from: session.currentUser) }
        .task {
            // The privacy fields ride GET /me (additive) — reconcile with the server.
            if let fresh = try? await APIClient.shared.me() {
                session.updateCurrentUser(fresh)
                syncPrivacy(from: fresh)
            }
        }
        // §11.6: one shared Everybody / My friends / Nobody selector for every row.
        .klicSelectionSheet(
            isPresented: Binding(
                get: { activeField != nil },
                set: { if !$0 { activeField = nil } }
            ),
            title: activeField?.title ?? "",
            message: activeField?.sheetMessage,
            options: KlicVisibility.allCases.map { KlicSheetOption(id: $0.rawValue, label: $0.label) },
            selectedId: activeField.map { visibility(for: $0).rawValue }
        ) { option in
            guard let field = activeField, let picked = KlicVisibility(rawValue: option.id) else { return }
            activeField = nil
            Task { await saveVisibility(picked, for: field) }
        }
        .klicSelectionSheet(
            isPresented: $showAwaySheet,
            title: String(localized: "Delete my account if away for"),
            message: String(localized: "Your account is deleted if you don't come online for this long."),
            options: [KlicSheetOption(id: "off", label: String(localized: "Never"))]
                + Self.awayOptions.map { KlicSheetOption(id: "\($0)", label: awayLabel($0)) },
            selectedId: deleteIfAwayMonths.map { "\($0)" } ?? "off"
        ) { option in
            let months = Int(option.id)
            Task { await saveAwayWindow(months) }
        }
        // Delete Account Now — double confirm (§10.4): sheet, then type the username.
        .klicSelectionSheet(
            isPresented: $showDeleteConfirm,
            title: String(localized: "Delete your account?"),
            message: String(localized: "This permanently deletes your account, messages and media for everyone. This cannot be undone."),
            options: [KlicSheetOption(id: "continue", label: String(localized: "Continue"), isDestructive: true)]
        ) { _ in
            typedUsername = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showDeleteTypeConfirm = true
            }
        }
        .alert(String(localized: "Type your username to confirm"), isPresented: $showDeleteTypeConfirm) {
            TextField(String(localized: "Username"), text: $typedUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete Forever"), role: .destructive) {
                Task { await deleteAccountNow() }
            }
        } message: {
            Text("Enter \"\(session.currentUser?.username ?? "")\" to permanently delete your account.")
        }
    }

    // MARK: Privacy card (§11.6)

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Privacy")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ForEach(PrivacyField.allCases) { field in
                Button { activeField = field } label: {
                    PrivacyRow(icon: field.icon, title: field.title, value: visibility(for: field).label)
                }
                .buttonStyle(.plain)
                .disabled(savingPrivacy)
                Divider().padding(.leading, 64).opacity(0.4)
            }

            // Calls → silence unknown callers (§11.6).
            toggleRow(
                icon: "phone.badge.waveform",
                title: String(localized: "Silence unknown callers"),
                subtitle: String(localized: "Calls from people who aren't your friends won't ring. They still appear in Recent Calls."),
                isOn: $silenceUnknownCallers
            )
            .onChange(of: silenceUnknownCallers) { _, value in
                guard !syncingToggles else { return }
                Task { await saveToggle("silenceUnknownCallers", value) }
            }

            Divider().padding(.leading, 64).opacity(0.4)

            // Read receipts — reciprocal, DMs only (§11.6).
            toggleRow(
                icon: "checkmark.message",
                title: String(localized: "Read receipts"),
                subtitle: String(localized: "If turned off, you won't send or receive read receipts in chats. Groups always send them."),
                isOn: $readReceipts
            )
            .onChange(of: readReceipts) { _, value in
                guard !syncingToggles else { return }
                Task { await saveToggle("readReceipts", value) }
            }

            if let privacyError {
                Text(privacyError)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.danger)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            Color.clear.frame(height: 8)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func toggleRow(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text(subtitle)
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .tint(KlicColor.primary)
            .disabled(savingPrivacy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func visibility(for field: PrivacyField) -> KlicVisibility {
        visibilities[field] ?? field.defaultVisibility
    }

    private func syncPrivacy(from user: User?) {
        guard let user else { return }
        syncingToggles = true
        visibilities[.lastSeen] = user.lastSeenVisibility.flatMap(KlicVisibility.init) ?? .friends
        visibilities[.about] = user.aboutVisibility.flatMap(KlicVisibility.init) ?? .everybody
        visibilities[.avatar] = user.avatarVisibility.flatMap(KlicVisibility.init) ?? .everybody
        visibilities[.links] = user.linksVisibility.flatMap(KlicVisibility.init) ?? .everybody
        visibilities[.groups] = user.groupsVisibility.flatMap(KlicVisibility.init) ?? .everybody
        visibilities[.status] = user.statusVisibility.flatMap(KlicVisibility.init) ?? .everybody
        silenceUnknownCallers = user.silenceUnknownCallers ?? false
        readReceipts = user.readReceipts ?? true
        DispatchQueue.main.async { syncingToggles = false }
    }

    private func saveVisibility(_ value: KlicVisibility, for field: PrivacyField) async {
        let previous = visibilities[field]
        visibilities[field] = value
        savingPrivacy = true
        defer { savingPrivacy = false }
        privacyError = nil
        do {
            let user = try await APIClient.shared.updateMe([field.rawValue: value.rawValue])
            session.updateCurrentUser(user)
            syncPrivacy(from: user)
        } catch let e as APIError {
            visibilities[field] = previous
            privacyError = e.userMessage
        } catch {
            visibilities[field] = previous
            privacyError = String(localized: "Couldn't save the setting.")
        }
    }

    private func saveToggle(_ key: String, _ value: Bool) async {
        savingPrivacy = true
        defer { savingPrivacy = false }
        privacyError = nil
        do {
            let user = try await APIClient.shared.updateMe([key: value])
            session.updateCurrentUser(user)
            syncPrivacy(from: user)
        } catch let e as APIError {
            privacyError = e.userMessage
            syncPrivacy(from: session.currentUser)
        } catch {
            privacyError = String(localized: "Couldn't save the setting.")
            syncPrivacy(from: session.currentUser)
        }
    }

    private func awayLabel(_ months: Int?) -> String {
        guard let months else { return String(localized: "Never") }
        return months == 1 ? String(localized: "1 month") : String(localized: "\(months) months")
    }

    private func saveAwayWindow(_ months: Int?) async {
        accountError = nil
        do {
            _ = try await APIClient.shared.setDeleteIfAway(months: months)
            deleteIfAwayMonths = months
        } catch let e as APIError {
            accountError = e.userMessage
        } catch {
            accountError = String(localized: "Couldn't save the setting.")
        }
    }

    private func deleteAccountNow() async {
        guard typedUsername.trimmingCharacters(in: .whitespaces).lowercased()
                == (session.currentUser?.username ?? "").lowercased() else {
            accountError = String(localized: "The username didn't match — account not deleted.")
            return
        }
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.deleteAccount()
            // Wipe local state and sign out.
            ChatDrafts.deleteAll()
            ChatCaches.clear()
            session.logout()
        } catch let e as APIError {
            accountError = e.userMessage
        } catch {
            accountError = String(localized: "Couldn't delete the account right now.")
        }
    }
}

struct PrivacyRow: View {
    let icon: String
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            if let value {
                Text(value)
                    .font(KlicFont.body(14))
                    .foregroundStyle(KlicColor.textMuted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - Blocked Users (§10.4)

struct BlockedUsersView: View {
    @State private var blocked: [BlockedUser] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var unblockingIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView()
                            .tint(KlicColor.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if blocked.isEmpty {
                        Text("You haven't blocked anyone.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(blocked.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                            if index < blocked.count - 1 {
                                Divider().padding(.leading, 74).opacity(0.4)
                            }
                        }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                if let errorText {
                    Text(errorText)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ entry: BlockedUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: entry.user.avatarUrl, name: entry.user.displayName, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.user.displayName)
                    .font(KlicFont.medium())
                    .foregroundStyle(KlicColor.textPrimary)
                Text("@\(entry.user.username)")
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
            }
            Spacer()
            Button {
                Task { await unblock(entry) }
            } label: {
                if unblockingIds.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Unblock")
                        .font(KlicFont.medium(13))
                        .foregroundStyle(KlicColor.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(KlicColor.primary.opacity(0.1), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(unblockingIds.contains(entry.id))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func load() async {
        loading = blocked.isEmpty
        defer { loading = false }
        do {
            blocked = try await APIClient.shared.blockedUsers()
            errorText = nil
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't load your blocked users.")
        }
    }

    private func unblock(_ entry: BlockedUser) async {
        unblockingIds.insert(entry.id)
        defer { unblockingIds.remove(entry.id) }
        do {
            // §16.6: route through the store so any open blocked-DM banner clears too.
            try await BlockStore.shared.unblock(userId: entry.user.id)
            blocked.removeAll { $0.id == entry.id }
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't unblock \(entry.user.displayName).")
        }
    }
}
