import SwiftUI

/// Settings → Notifications (CALLS.md §8.5): the four global push toggles synced via
/// GET/PUT /me/notification-prefs, the global default ringtone (what CallKit rings
/// with), and "Reset notification settings" (DELETE + local tone prefs reset).
struct NotificationsSettingsView: View {
    @State private var prefs = ChatLocalPrefs.cachedGlobalPrefs()
    @State private var loaded = false
    @State private var saving = false
    @State private var showResetConfirm = false
    @State private var showRingtoneSheet = false
    @State private var ringtone = ChatLocalPrefs.globalRingtone

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                togglesCard
                ringtoneCard

                PillButton(title: String(localized: "Reset notification settings"), fill: KlicColor.surface, textColor: KlicColor.danger) {
                    showResetConfirm = true
                }

                Text("Message, group, call and friend-request pushes are filtered server-side by these switches. Alert tones are per-device; the sound of a delivered push notification stays the system default.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Tolerates the server not being deployed yet — falls back to the cached copy.
            if let fetched = try? await APIClient.shared.notificationPrefs() {
                prefs = fetched
                ChatLocalPrefs.cacheGlobalPrefs(fetched)
            }
            loaded = true
        }
        .klicSelectionSheet(
            isPresented: $showResetConfirm,
            title: String(localized: "Reset notification settings?"),
            message: String(localized: "Turns every notification back on and restores the default tones."),
            options: [KlicSheetOption(id: "reset", label: String(localized: "Reset"), isDestructive: true)]
        ) { _ in
            Task { await reset() }
        }
        .klicSelectionSheet(
            isPresented: $showRingtoneSheet,
            title: String(localized: "Ringtone"),
            options: KlicTone.ringtones.map { KlicSheetOption(id: $0.id, label: $0.name) },
            selectedId: ringtone ?? "default",
            dismissOnSelect: false,
            onDismiss: { TonePreviewPlayer.shared.stop() }
        ) { option in
            guard let tone = KlicTone.ringtones.first(where: { $0.id == option.id }) else { return }
            ringtone = tone.file
            ChatLocalPrefs.globalRingtone = tone.file
            CallKitManager.shared.updateRingtone()
            TonePreviewPlayer.shared.preview(tone)
        }
    }

    private var togglesCard: some View {
        VStack(spacing: 0) {
            toggleRow("Message notifications", icon: "message", value: bindingFor(\.messages))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Group notifications", icon: "person.3", value: bindingFor(\.groups))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Call notifications", icon: "phone", value: bindingFor(\.calls))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Friend requests", icon: "person.badge.plus", value: bindingFor(\.friendRequests))
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var ringtoneCard: some View {
        VStack(spacing: 0) {
            Button {
                showRingtoneSheet = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(KlicColor.primary)
                        .frame(width: 32, height: 32)
                        .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text("Ringtone")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text(KlicTone.ringtones.first(where: { $0.file == ringtone })?.name ?? "Klic")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textMuted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.textMuted)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func toggleRow(_ title: String, icon: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Toggle(title, isOn: value)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .disabled(saving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func bindingFor(_ keyPath: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { prefs[keyPath: keyPath] },
            set: { newValue in
                let previous = prefs
                prefs[keyPath: keyPath] = newValue
                ChatLocalPrefs.cacheGlobalPrefs(prefs)
                guard loaded else { return }
                Task { await push(previous: previous) }
            }
        )
    }

    private func push(previous: NotificationPrefs) async {
        saving = true
        defer { saving = false }
        do {
            let updated = try await APIClient.shared.updateNotificationPrefs(
                messages: prefs.messages, groups: prefs.groups,
                calls: prefs.calls, friendRequests: prefs.friendRequests
            )
            prefs = updated
            ChatLocalPrefs.cacheGlobalPrefs(updated)
        } catch {
            // Server unreachable / endpoint not deployed — keep the local copy, revert nothing
            // hard: the cached copy still applies to foreground gating.
            _ = previous
        }
    }

    private func reset() async {
        try? await APIClient.shared.resetNotificationPrefs()
        prefs = .defaults
        ChatLocalPrefs.cacheGlobalPrefs(.defaults)
        ChatLocalPrefs.resetAllTones()
        ringtone = ChatLocalPrefs.globalRingtone
        CallKitManager.shared.updateRingtone()
    }
}
