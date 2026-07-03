import SwiftUI

/// Notifications section shown on BOTH chat-info pages (CALLS.md §8.4).
///
/// - Messages: mute (8 hours / 1 week / Always → PUT /conversations/:id/prefs),
///   "Mute @all mentions" (groups only), Alert tone (bundled list, LOCAL pref —
///   applies to in-app/foreground sounds; the APNs push sound stays default).
/// - Calls: mute (same durations → callsMutedUntil) and Ringtone (LOCAL pref;
///   CallKit's actual ring is the single global pick from Settings → Notifications —
///   iOS cannot vary the CallKit ringtone per chat).
///
/// All pickers use the shared Klic bottom sheet (§9.2); tone previews stop the
/// moment their sheet closes (§9.4).
struct ChatNotificationsCard: View {
    let conversationId: String
    let isGroup: Bool

    @State private var prefs = ConversationPrefs(messagesMutedUntil: nil, muteMentions: false, callsMutedUntil: nil)
    @State private var loaded = false
    @State private var muteMentions = false
    @State private var alertTone: String?
    @State private var ringtone: String?
    @State private var showMessageMuteSheet = false
    @State private var showCallMuteSheet = false
    @State private var showAlertToneSheet = false
    @State private var showRingtoneSheet = false

    init(conversationId: String, isGroup: Bool) {
        self.conversationId = conversationId
        self.isGroup = isGroup
        _alertTone = State(initialValue: ChatLocalPrefs.alertTone(conversationId))
        _ringtone = State(initialValue: ChatLocalPrefs.ringtone(conversationId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Notifications")

            // Messages
            Button {
                showMessageMuteSheet = true
            } label: {
                valueRow(icon: "message", title: String(localized: "Mute messages"),
                         value: ChatLocalPrefs.muteSummary(prefs.messagesMutedUntil))
            }
            .buttonStyle(.plain)

            if isGroup {
                Divider().padding(.leading, 64).opacity(0.4)
                HStack(spacing: 14) {
                    rowIcon("at")
                    Toggle("Mute @all mentions", isOn: $muteMentions)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .tint(KlicColor.primary)
                        .onChange(of: muteMentions) { _, newValue in
                            guard loaded else { return }
                            Task { await push(muteMentions: newValue) }
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 64).opacity(0.4)

            Button {
                showAlertToneSheet = true
            } label: {
                valueRow(icon: "bell", title: String(localized: "Alert tone"),
                         value: KlicTone.alertTones.first(where: { $0.file == alertTone })?.name ?? "Default")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Calls
            Button {
                showCallMuteSheet = true
            } label: {
                valueRow(icon: "phone", title: String(localized: "Mute calls"),
                         value: ChatLocalPrefs.muteSummary(prefs.callsMutedUntil))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            Button {
                showRingtoneSheet = true
            } label: {
                valueRow(icon: "bell.badge", title: String(localized: "Ringtone"),
                         value: KlicTone.ringtones.first(where: { $0.file == (ringtone ?? ChatLocalPrefs.globalRingtone) })?.name ?? "Klic")
            }
            .buttonStyle(.plain)

            Text("Tones are stored on this device. Delivered push notifications keep the default sound, and the incoming-call ring uses the global ringtone from Settings → Notifications.")
                .font(KlicFont.caption(11))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .task { await load() }
        .klicSelectionSheet(
            isPresented: $showMessageMuteSheet,
            title: String(localized: "Mute messages"),
            options: Self.muteOptions,
            selectedId: Self.muteSelectionId(prefs.messagesMutedUntil)
        ) { option in
            Task { await push(messagesMutedUntil: Self.muteValue(for: option.id)) }
        }
        .klicSelectionSheet(
            isPresented: $showCallMuteSheet,
            title: String(localized: "Mute call notifications"),
            options: Self.muteOptions,
            selectedId: Self.muteSelectionId(prefs.callsMutedUntil)
        ) { option in
            Task { await push(callsMutedUntil: Self.muteValue(for: option.id)) }
        }
        .klicSelectionSheet(
            isPresented: $showAlertToneSheet,
            title: String(localized: "Alert tone"),
            options: KlicTone.alertTones.map { KlicSheetOption(id: $0.id, label: $0.name) },
            selectedId: alertTone ?? "default",
            dismissOnSelect: false,
            onDismiss: { TonePreviewPlayer.shared.stop() }
        ) { option in
            guard let tone = KlicTone.alertTones.first(where: { $0.id == option.id }) else { return }
            alertTone = tone.file
            ChatLocalPrefs.setAlertTone(tone.file, conversationId)
            TonePreviewPlayer.shared.preview(tone)
        }
        .klicSelectionSheet(
            isPresented: $showRingtoneSheet,
            title: String(localized: "Ringtone"),
            options: KlicTone.ringtones.map { KlicSheetOption(id: $0.id, label: $0.name) },
            selectedId: ringtone ?? ChatLocalPrefs.globalRingtone ?? "default",
            dismissOnSelect: false,
            onDismiss: { TonePreviewPlayer.shared.stop() }
        ) { option in
            guard let tone = KlicTone.ringtones.first(where: { $0.id == option.id }) else { return }
            ringtone = tone.file
            ChatLocalPrefs.setRingtone(tone.file, conversationId)
            TonePreviewPlayer.shared.preview(tone)
        }
    }

    // MARK: Mute options

    private static let muteOptions: [KlicSheetOption] = [
        KlicSheetOption(id: "8h", label: String(localized: "For 8 hours")),
        KlicSheetOption(id: "1w", label: String(localized: "For 1 week")),
        KlicSheetOption(id: "always", label: String(localized: "Always")),
        KlicSheetOption(id: "off", label: String(localized: "Unmute")),
    ]

    private static func muteValue(for id: String) -> String? {
        switch id {
        case "8h": return ChatLocalPrefs.isoString(Date().addingTimeInterval(8 * 3600))
        case "1w": return ChatLocalPrefs.isoString(Date().addingTimeInterval(7 * 24 * 3600))
        case "always": return ChatLocalPrefs.alwaysMutedISO
        default: return nil
        }
    }

    private static func muteSelectionId(_ iso: String?) -> String? {
        guard let date = ChatLocalPrefs.parseISO(iso), date > Date() else { return "off" }
        return date.timeIntervalSinceNow > 365 * 24 * 3600 ? "always" : nil
    }

    // MARK: Rows

    private func header(_ title: String) -> some View {
        Text(title)
            .font(KlicFont.headline(17))
            .foregroundStyle(KlicColor.textPrimary)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(KlicColor.primary)
            .frame(width: 32, height: 32)
            .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            rowIcon(icon)
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Text(value)
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Sync

    private func load() async {
        // try? — tolerate a server without the endpoint; local cache still applies.
        if let fetched = try? await APIClient.shared.conversationPrefs(conversationId: conversationId) {
            prefs = fetched
            ChatLocalPrefs.cacheMutes(conversationId, prefs: fetched)
        }
        muteMentions = prefs.muteMentions ?? false
        loaded = true
    }

    private func push(
        messagesMutedUntil: String?? = nil,
        muteMentions: Bool? = nil,
        callsMutedUntil: String?? = nil
    ) async {
        // Optimistic local update — foreground gating keeps working even when the
        // server hasn't shipped the endpoint yet.
        if let value = messagesMutedUntil { prefs.messagesMutedUntil = value }
        if let muteMentions { prefs.muteMentions = muteMentions }
        if let value = callsMutedUntil { prefs.callsMutedUntil = value }
        ChatLocalPrefs.cacheMutes(conversationId, prefs: prefs)

        if let updated = try? await APIClient.shared.updateConversationPrefs(
            conversationId: conversationId,
            messagesMutedUntil: messagesMutedUntil,
            muteMentions: muteMentions,
            callsMutedUntil: callsMutedUntil
        ) {
            prefs = updated
            self.muteMentions = updated.muteMentions ?? false
            ChatLocalPrefs.cacheMutes(conversationId, prefs: updated)
        }
    }
}
