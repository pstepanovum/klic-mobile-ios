import SwiftUI

/// Settings → Privacy and Security (§10.4): rounded cards for Blocked Users,
/// Passcode & Face ID, Passkeys, Open links in, Data Settings and account deletion,
/// plus the existing "Last seen" privacy toggle.
struct PrivacySecurityView: View {
    @EnvironmentObject var session: AppSession

    // Last seen (kept from the previous Privacy page).
    @State private var showLastSeen = true
    @State private var savingLastSeen = false

    // Auto-delete account (§10.4).
    @State private var deleteIfAwayMonths: Int?
    @State private var showAwaySheet = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteTypeConfirm = false
    @State private var typedUsername = ""
    @State private var deleting = false
    @State private var accountError: String?

    private static let awayOptions = [1, 3, 6, 12, 18, 24]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Last seen
                VStack(spacing: 0) {
                    Toggle(isOn: $showLastSeen) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last seen")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text("If turned off, you won't see anyone else's last seen.")
                                .font(KlicFont.caption(12))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    .tint(KlicColor.primary)
                    .disabled(savingLastSeen)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .onChange(of: showLastSeen) { _, newValue in
                        guard newValue != (session.currentUser?.showLastSeen ?? true) else { return }
                        Task { await saveLastSeen(newValue) }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

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
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Privacy and Security")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { showLastSeen = session.currentUser?.showLastSeen ?? true }
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

    private func awayLabel(_ months: Int?) -> String {
        guard let months else { return String(localized: "Never") }
        return months == 1 ? String(localized: "1 month") : String(localized: "\(months) months")
    }

    private func saveLastSeen(_ value: Bool) async {
        savingLastSeen = true
        defer { savingLastSeen = false }
        if let user = try? await APIClient.shared.updateProfile(showLastSeen: value) {
            session.updateCurrentUser(user)
        } else {
            showLastSeen = session.currentUser?.showLastSeen ?? true
        }
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
            .adaptiveWidth()
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
            try await APIClient.shared.unblockUser(userId: entry.user.id)
            blocked.removeAll { $0.id == entry.id }
        } catch let e as APIError {
            errorText = e.userMessage
        } catch {
            errorText = String(localized: "Couldn't unblock \(entry.user.displayName).")
        }
    }
}
