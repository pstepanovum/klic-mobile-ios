import Foundation
import CallKit
import AVFoundation
import UIKit

/// Central call coordinator. Bridges CallKit (the system call UI shown on the Lock Screen and
/// in the Dynamic Island) with the LiveKit media session and the Live Activity.
@MainActor
final class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()

    struct ActiveCall: Identifiable {
        let id: String          // callId
        let roomName: String
        let livekitUrl: String
        var token: String
        let kind: String
        let peerName: String    // display label: peer name, or "<Caller> · <Group title>" for groups
        var peerId: String?
        var peerAvatarUrl: String?
        let isOutgoing: Bool
        var conversationId: String? = nil
        var isGroup: Bool = false
        var isVideo: Bool { kind == "VIDEO" }
    }

    /// When set, the app shows the in-call screen.
    @Published var activeCall: ActiveCall? {
        didSet {
            // Switching to a different call (or ending this one) always exits the
            // minimized state and restarts the connected-timer baseline. In-place
            // reassignments of the same call keep both.
            guard activeCall?.id != oldValue?.id else { return }
            callMinimized = false
            connectedAt = nil
        }
    }
    /// True while the in-call screen is collapsed into the floating root overlay so the
    /// user can browse the app mid-call. UI-only: the CallKit call and the LiveKit room
    /// are untouched; RootView derives the fullScreenCover's item from this flag.
    @Published var callMinimized = false
    /// When media first connected for the current call — drives the minimized pill's
    /// live timer. Reset whenever the active call changes.
    @Published private(set) var connectedAt: Date?
    @Published var statusText = "Calling..."

    private let provider: CXProvider
    private let controller = CXCallController()
    private let uuidMapDefaultsKey = "klic.callkit.uuidToCallId"
    private var uuidToCallId: [UUID: String] = [:]
    private var callIdToUUID: [String: UUID] = [:]
    private var pendingInvites: [String: SocketService.CallInvite] = [:]
    /// Ring timeouts keyed by callId — never share one task across calls, or an overlapping
    /// call clobbers the other's timeout and the abandoned call never self-cancels.
    private var ringTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var finishingCallIds = Set<String>()
    private var recentlyEndedCallIds = Set<String>()
    /// CallIds CallKit has told us to put on hold (CXSetHeldCallAction, isOnHold == true).
    /// Recorded synchronously so the answer handler can distinguish "Hold & Accept" (a hold was
    /// reported for our current call) from "End & Accept" (no hold — the call is being ended).
    private var heldViaCallKit = Set<String>()
    /// Deduped set so the end/drop haptic fires exactly once per call.
    private var endHapticCallIds = Set<String>()

    override init() {
        provider = CXProvider(configuration: Self.providerConfiguration())
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    private static func providerConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // Show finished calls in the native Phone app's Recents (All / Missed), labeled
        // "Klic Audio" / "Klic Video" — standard messenger behavior. Missed/declined calls show
        // in red. (Tapping an entry's call-back triggers a CXStartCallAction with the stored generic
        // handle; see provider(perform: CXStartCallAction) for how a Recents call-back is handled.)
        config.includesCallsInRecents = true
        // Custom ringtone CallKit plays for an incoming voice/video call (bundled CallKit-
        // compatible sound). Falls back to the system ringtone if the resource is missing.
        // CallKit only supports ONE global ringtone — the Settings → Notifications pick.
        // Per-chat ringtone selections apply where the app itself controls playback.
        config.ringtoneSound = ChatLocalPrefs.globalRingtone ?? "ringtone.caf"
        return config
    }

    /// Re-apply the provider configuration after the global ringtone pick changes.
    /// Configuration-only — call/audio sequencing is untouched.
    func updateRingtone() {
        provider.configuration = Self.providerConfiguration()
    }

    // MARK: Incoming (from socket or VoIP push)

    /// `fromPushKit` marks a VoIP-push-originated report. PushKit's "must report" contract (H2)
    /// requires `reportNewIncomingCall` to fire for EVERY delivered VoIP push before the push's
    /// completion handler — skipping it (even on a dedup/stale path) makes iOS terminate the app
    /// and eventually stop launching it for VoIP pushes, which is itself a cause of missed rings.
    /// So on the push path the early-return branches still report: a stale/dead call is reported
    /// then immediately ended, and a duplicate of an already-reported call is re-reported on the
    /// same UUID (a harmless "already exists" that still satisfies the contract). The socket path
    /// (fromPushKit == false) keeps its quiet dedup — no push to answer to.
    func reportIncoming(_ invite: SocketService.CallInvite, fromPushKit: Bool = false, completion: (() -> Void)? = nil) {
        APIClient.mobileDiagnostic(event: "callkit.reportIncoming", callId: invite.id, detail: invite.fromDisplayName)
        if recentlyEndedCallIds.contains(invite.id) {
            APIClient.mobileDiagnostic(event: "callkit.reportIncoming.ignoredEnded", callId: invite.id)
            if fromPushKit {
                // Dead call, but the push must be reported — report then end immediately.
                reportEndedForCompliance(callId: invite.id, invite: invite, completion: completion)
            } else {
                completion?()
            }
            return
        }
        let uuid = uuid(for: invite.id)
        if pendingInvites[invite.id] != nil {
            APIClient.mobileDiagnostic(
                event: "callkit.reportIncoming.duplicate",
                callId: invite.id,
                detail: uuid.uuidString
            )
            if fromPushKit {
                // Already reported (typically via the socket copy); re-report on the SAME UUID
                // to satisfy must-report. CallKit returns "already exists" without re-ringing.
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: invite.displayTitle)
                update.hasVideo = invite.kind == "VIDEO"
                update.supportsHolding = true
                provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion?() }
            } else {
                completion?()
            }
            return
        }
        pendingInvites[invite.id] = invite
        let update = CXCallUpdate()
        // Group invites ring as "<Caller> · <Group title>" so the system UI shows both.
        update.remoteHandle = CXHandle(type: .generic, value: invite.displayTitle)
        update.hasVideo = invite.kind == "VIDEO"
        // Answering a native call mid-Klic-call should HOLD us (CXSetHeldCallAction),
        // not force the user into "End & Accept".
        update.supportsHolding = true
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                APIClient.mobileDiagnostic(
                    event: "callkit.reportIncoming.failed",
                    callId: invite.id,
                    detail: String(describing: error)
                )
            } else {
                APIClient.mobileDiagnostic(event: "callkit.reportIncoming.ok", callId: invite.id)
            }
            completion?()
        }
    }

    // MARK: Outgoing (user taps call)

    func startOutgoing(
        _ session: CallSession,
        peerName: String,
        peerId: String? = nil,
        peerAvatarUrl: String? = nil,
        conversationId: String? = nil,
        isGroup: Bool = false
    ) {
        if activeCall != nil {
            APIClient.mobileDiagnostic(
                event: "callkit.start.ignored.activeCall",
                callId: session.callId,
                detail: peerName
            )
            Task { try? await APIClient.shared.cancelCall(callId: session.callId) }
            return
        }
        let uuid = uuid(for: session.callId)
        statusText = "Calling..."
        activeCall = ActiveCall(
            id: session.callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
            token: session.token, kind: session.kind ?? "AUDIO", peerName: peerName,
            peerId: peerId, peerAvatarUrl: peerAvatarUrl, isOutgoing: true,
            conversationId: conversationId, isGroup: isGroup
        )
        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = session.kind == "VIDEO"
        controller.request(CXTransaction(action: action)) { _ in }
        startRingTimeout(callId: session.callId)
        // Teach Siri/CarPlay Suggestions "call <peer> on Klic" (1:1 only — a group label
        // can't be resolved back to a contact).
        if !isGroup { CallIntents.donate(peerName: peerName, peerId: peerId, isVideo: session.kind == "VIDEO") }
    }

    /// Join a call that's already in progress (the group chat's "Join call" banner). No incoming
    /// report — the system sees it as an outgoing call (CXStartCallAction, same as startOutgoing)
    /// so the green pill / Dynamic Island show an active call. No ringback or ring timeout: the
    /// call is live, we're just late-joining it.
    func joinOngoing(callId: String, conversationId: String, title: String, kind fallbackKind: String) async {
        guard activeCall == nil else {
            APIClient.mobileDiagnostic(event: "callkit.joinOngoing.ignored.activeCall", callId: callId)
            return
        }
        guard let session = try? await APIClient.shared.joinToken(callId: callId) else {
            APIClient.mobileDiagnostic(event: "callkit.joinOngoing.token.failed", callId: callId)
            return
        }
        let kind = session.kind ?? fallbackKind
        let uuid = uuid(for: callId)
        statusText = "Connecting..."
        activeCall = ActiveCall(
            id: callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
            token: session.token, kind: kind, peerName: title,
            peerId: nil, peerAvatarUrl: nil, isOutgoing: true,
            conversationId: conversationId, isGroup: true
        )
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
        action.isVideo = kind == "VIDEO"
        try? await controller.request(CXTransaction(action: action))
        APIClient.mobileDiagnostic(event: "callkit.joinOngoing.start", callId: callId)
    }

    // MARK: In-call controls routed through CallKit

    func requestEnd() {
        guard let id = activeCall?.id else { return }
        guard let uuid = callIdToUUID[id] else {
            APIClient.mobileDiagnostic(event: "callkit.end.fallback.missingUUID", callId: id)
            finishCall(callId: id, status: "Ended", notifyServer: true, dismissAfter: 0)
            return
        }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error {
                APIClient.mobileDiagnostic(
                    event: "callkit.end.request.failed",
                    callId: id,
                    detail: String(describing: error)
                )
                Task { @MainActor in
                    self.finishCall(callId: id, status: "Ended", notifyServer: true, dismissAfter: 0)
                }
            }
        }
    }

    func requestSetMuted(_ muted: Bool) {
        guard let id = activeCall?.id, let uuid = callIdToUUID[id] else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { _ in }
    }

    // MARK: Helpers

    private func uuid(for callId: String) -> UUID {
        if let existing = callIdToUUID[callId] { return existing }
        let uuid = UUID()
        callIdToUUID[callId] = uuid
        uuidToCallId[uuid] = callId
        persist(callId: callId, for: uuid)
        return uuid
    }

    private func clear(_ callId: String) {
        if let uuid = callIdToUUID[callId] {
            uuidToCallId[uuid] = nil
            removePersistedCallId(for: uuid)
        }
        callIdToUUID[callId] = nil
        pendingInvites[callId] = nil
        heldViaCallKit.remove(callId)
        endHapticCallIds.remove(callId)
        cancelRingTimeout(callId)
    }

    private func cancelRingTimeout(_ callId: String) {
        ringTimeoutTasks[callId]?.cancel()
        ringTimeoutTasks[callId] = nil
    }

    private func cancelAllRingTimeouts() {
        for task in ringTimeoutTasks.values { task.cancel() }
        ringTimeoutTasks.removeAll()
    }

    private func callId(for uuid: UUID) -> String? {
        if let callId = uuidToCallId[uuid] { return callId }
        let fallbackCallId: String?
        if let persisted = persistedCallId(for: uuid) {
            fallbackCallId = persisted
        } else if pendingInvites.count == 1 {
            fallbackCallId = pendingInvites.keys.first
        } else if callIdToUUID.count == 1 {
            // The in-memory/persisted map was lost but we only know one call — answer it
            // rather than failing outright (CallKit hands us a UUID we must resolve).
            fallbackCallId = callIdToUUID.keys.first
        } else if let single = persistedSingleCallId() {
            // A fresh process (VoIP push launched the app) has empty in-memory maps, but
            // persisted state holds exactly one call — resolve to it instead of failing.
            fallbackCallId = single
        } else {
            fallbackCallId = nil
        }
        guard let callId = fallbackCallId else { return nil }
        uuidToCallId[uuid] = callId
        callIdToUUID[callId] = uuid
        persist(callId: callId, for: uuid)
        return callId
    }

    private func persist(callId: String, for uuid: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        map[uuid.uuidString] = callId
        UserDefaults.standard.set(map, forKey: uuidMapDefaultsKey)
    }

    private func persistedCallId(for uuid: UUID) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String]
        return map?[uuid.uuidString]
    }

    /// The single persisted callId, when exactly one call is known — used to resolve a CallKit
    /// answer UUID after a cold launch where the in-memory maps are empty.
    private func persistedSingleCallId() -> String? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String]
        return map?.count == 1 ? map?.values.first : nil
    }

    private func persistedUUID(for callId: String) -> UUID? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        return map.first(where: { $0.value == callId }).flatMap { UUID(uuidString: $0.key) }
    }

    /// EVERY persisted UUID mapped to this callId. The app's in-memory UUID for a call can drift
    /// from the UUID CallKit actually holds the call under (device traces show the end-action UUID
    /// never matching the reported-ended UUID). Used so we end-report all of them, not just one.
    private func persistedUUIDs(for callId: String) -> [UUID] {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        return map.compactMap { $0.value == callId ? UUID(uuidString: $0.key) : nil }
    }

    private func restorePersistedMapping(for callId: String) {
        guard callIdToUUID[callId] == nil, let uuid = persistedUUID(for: callId) else { return }
        callIdToUUID[callId] = uuid
        uuidToCallId[uuid] = callId
    }

    private func removePersistedCallId(for uuid: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        map[uuid.uuidString] = nil
        UserDefaults.standard.set(map, forKey: uuidMapDefaultsKey)
    }

    private func endSystemCall(callId: String, reason: CXCallEndedReason = .remoteEnded) {
        // End EVERY CallKit UUID we've ever associated with this call (in-memory + persisted).
        // The app's stored UUID and the UUID CallKit holds the live call under can drift apart
        // (confirmed in device traces: end.enter UUID != reportEnded UUID). Reporting ended on the
        // wrong UUID silently no-ops and leaves the system call stuck on the Lock Screen / as a
        // green pill after the peer hangs up. reportCall(endedAt:) on an unknown/already-ended UUID
        // is harmless, so ending all known UUIDs guarantees the live one is actually dismissed.
        var uuids = Set<UUID>(persistedUUIDs(for: callId))
        if let current = callIdToUUID[callId] { uuids.insert(current) }
        guard !uuids.isEmpty else {
            APIClient.mobileDiagnostic(event: "callkit.reportEnded.noUUID", callId: callId)
            return
        }
        for uuid in uuids {
            APIClient.mobileDiagnostic(event: "callkit.reportEnded", callId: callId, detail: uuid.uuidString)
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        }
    }

    private func startRingTimeout(callId: String) {
        cancelRingTimeout(callId)
        ringTimeoutTasks[callId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await MainActor.run {
                guard let self, self.activeCall?.id == callId, self.statusText != "Connected" else { return }
                self.statusText = "No answer"
                Task { try? await APIClient.shared.cancelCall(callId: callId) }
                if let uuid = self.callIdToUUID[callId] {
                    self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
                }
            }
        }
    }

    /// Record when the call's media first connected (idempotent — reconnects keep the
    /// original baseline so the minimized pill's timer doesn't restart).
    private func markConnected() {
        if connectedAt == nil { connectedAt = Date() }
    }

    /// Whether media was established for the current call. "Reconnecting…" and "On Hold" count:
    /// the call WAS connected and is only riding out a blip/hold — ending it then must be a
    /// server `end` (outcome completed), not a decline/cancel.
    private var isMediaConnected: Bool {
        statusText == "Connected" || statusText == "Reconnecting…" || statusText == "On Hold"
    }

    /// The in-flight server-side teardown (end/cancel/decline) of the most recently finished
    /// call. Starting a new call awaits this first — otherwise POST /calls races our own
    /// teardown, bounces off 409 call_exists for the call we just left, and the tap appears
    /// to do nothing (the "dead call button right after hanging up" bug).
    private var serverTeardown: Task<Void, Never>?

    func awaitServerTeardown() async {
        _ = await serverTeardown?.value
    }

    private func finishCallOnServer(callId: String, wasOutgoing: Bool, wasConnected: Bool) async {
        if wasConnected {
            _ = try? await APIClient.shared.endCall(callId: callId)
        } else if wasOutgoing {
            _ = try? await APIClient.shared.cancelCall(callId: callId)
        } else {
            _ = try? await APIClient.shared.declineCall(callId: callId)
        }
    }

    /// Subtle one-shot haptic when a call ends or drops. Deduped per callId so overlapping
    /// end paths (local hang-up vs. a remote end arriving together) buzz at most once.
    private func playEndHaptic(_ callId: String?) {
        if let callId {
            guard !endHapticCallIds.contains(callId) else { return }
            endHapticCallIds.insert(callId)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Tear down a call that was on HOLD for call-waiting. Its LiveKit room is already gone
    /// (discarded when we answered the interrupting call), so this only notifies the server and
    /// clears the CallKit call — it must NOT touch the shared media session, which belongs to the
    /// currently active call.
    private func endHeldCall(_ callId: String, notifyServer: Bool) {
        guard !finishingCallIds.contains(callId) else { return }
        finishingCallIds.insert(callId)
        recentlyEndedCallIds.insert(callId)
        playEndHaptic(callId)
        if notifyServer {
            serverTeardown = Task { _ = try? await APIClient.shared.endCall(callId: callId) }
        }
        endSystemCall(callId: callId)
        CallService.shared.clearHeld()
        clear(callId)
        finishingCallIds.remove(callId)
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            _ = await MainActor.run { self.recentlyEndedCallIds.remove(callId) }
        }
    }

    /// After an active call ends, bring back any call we were holding for call-waiting.
    private func resumeHeldCallIfNeeded(endedCallId: String?) {
        guard let held = CallService.shared.heldCall, held.id != endedCallId else { return }
        resumeHeldCall()
    }

    /// Rejoin a call that was held for call-waiting once the interrupting call ends. The held
    /// call's LiveKit room was discarded when we answered the other call (single room at a time),
    /// so this fetches a fresh token and reconnects from scratch, restores it as the active call,
    /// and tells CallKit it's no longer held. Idempotent: it clears `heldCall` up front so a
    /// second trigger (our own end path AND CallKit's automatic unhold) can only run once.
    func resumeHeldCall() {
        guard let held = CallService.shared.heldCall else { return }
        CallService.shared.clearHeld()
        guard !recentlyEndedCallIds.contains(held.id) else { return }
        APIClient.mobileDiagnostic(event: "callkit.resumeHeld.start", callId: held.id)
        statusText = "Connecting..."
        activeCall = held
        Task { @MainActor in
            do {
                let session = try await APIClient.shared.joinToken(callId: held.id)
                try await CallService.shared.join(
                    callId: held.id, url: session.livekitUrl, token: session.token, video: held.isVideo
                )
                guard activeCall?.id == held.id, !recentlyEndedCallIds.contains(held.id) else { return }
                _ = try? await APIClient.shared.mediaJoined(callId: held.id)
                statusText = "Connected"
                markConnected()
                // CallKit usually auto-unholds the surviving call when the other ends; make sure.
                if let uuid = callIdToUUID[held.id] {
                    controller.request(CXTransaction(action: CXSetHeldCallAction(call: uuid, onHold: false))) { _ in }
                }
                CallActivityController.start(peerName: held.peerName, isVideo: held.isVideo)
                CallActivityController.update(status: "Connected", muted: false, isVideo: held.isVideo)
                APIClient.mobileDiagnostic(event: "callkit.resumeHeld.ok", callId: held.id)
            } catch {
                APIClient.mobileDiagnostic(
                    event: "callkit.resumeHeld.failed",
                    callId: held.id,
                    detail: String(describing: error)
                )
                finishCall(callId: held.id, status: "Ended", notifyServer: false, dismissAfter: 500_000_000)
            }
        }
    }

    private func finishCall(callId: String, status: String, notifyServer: Bool, dismissAfter seconds: UInt64 = 1_500_000_000, endReason: CXCallEndedReason = .remoteEnded) {
        guard !finishingCallIds.contains(callId) else { return }
        // A HELD (call-waiting) call ending must not run the normal teardown below — that would
        // leave() the shared media session and kill the ACTIVE call. Tear it down on its own.
        if callId != activeCall?.id, callId == CallService.shared.heldCall?.id {
            endHeldCall(callId, notifyServer: notifyServer)
            return
        }
        Ringback.shared.stop()
        playEndHaptic(callId)
        let wasOutgoing = activeCall?.id == callId ? activeCall?.isOutgoing == true : false
        let wasConnected = activeCall?.id == callId && isMediaConnected
        finishingCallIds.insert(callId)
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        statusText = status
        if activeCall?.id == callId {
            activeCall = nil
        }
        if notifyServer {
            serverTeardown = Task { await self.finishCallOnServer(callId: callId, wasOutgoing: wasOutgoing, wasConnected: wasConnected) }
        }
        endSystemCall(callId: callId, reason: endReason)
        Task {
            await CallService.shared.leave()
            CallActivityController.end()
            // The active call just ended — bring back any call we were holding for call-waiting.
            resumeHeldCallIfNeeded(endedCallId: callId)
            try? await Task.sleep(nanoseconds: seconds)
            await MainActor.run {
                self.clear(callId)
                self.finishingCallIds.remove(callId)
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    _ = await MainActor.run { self.recentlyEndedCallIds.remove(callId) }
                }
            }
        }
    }

    /// Tear down a call we're walking away from (because we're answering a different one)
    /// without touching the shared media session / Live Activity — the call we're switching
    /// to reconfigures those itself, so doing it here would race and kill the new call's UI.
    private func endAbandonedCall(_ callId: String) {
        let wasOutgoing = activeCall?.id == callId ? activeCall?.isOutgoing == true : true
        let wasConnected = activeCall?.id == callId && isMediaConnected
        Ringback.shared.stop()
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        serverTeardown = Task { await self.finishCallOnServer(callId: callId, wasOutgoing: wasOutgoing, wasConnected: wasConnected) }
        endSystemCall(callId: callId)
        clear(callId)
        if activeCall?.id == callId { activeCall = nil }
    }

    /// A peer accepted (socket call:accept) or their media joined (call:participant-joined —
    /// which also fires for repeat joins after a rejoin, so this must stay idempotent). Stops
    /// the ringback on the first occurrence; never clobbers a live "Reconnecting…" status.
    func handlePeerAccepted(callId: String) {
        guard activeCall?.id == callId else { return }
        Ringback.shared.stop()
        cancelRingTimeout(callId)
        guard statusText == "Calling..." || statusText == "Connecting..." else { return }
        statusText = "Connected"
        markConnected()
        CallActivityController.update(status: "Connected", muted: false, isVideo: activeCall?.isVideo ?? false)
    }

    /// LiveKit is re-establishing media after a network change — keep the call, show the state.
    func handleReconnecting(callId: String?) {
        guard let callId, activeCall?.id == callId, statusText == "Connected" else { return }
        statusText = "Reconnecting…"
        CallActivityController.update(
            status: "Reconnecting…",
            muted: !CallService.shared.micEnabled,
            isVideo: activeCall?.isVideo ?? false
        )
    }

    func handleReconnected(callId: String?) {
        guard let callId, activeCall?.id == callId, statusText == "Reconnecting…" else { return }
        statusText = "Connected"
        CallActivityController.update(
            status: "Connected",
            muted: !CallService.shared.micEnabled,
            isVideo: activeCall?.isVideo ?? false
        )
    }

    func handlePeerDeclined(callId: String) {
        if activeCall?.id == callId {
            // .unanswered shows "Missed" in the system call log — less confusing than the
            // "Unavailable" label that .remoteEnded produces for a call that was never answered.
            finishCall(callId: callId, status: "Busy", notifyServer: false, endReason: .unanswered)
        } else {
            handleRemoteCallEnded(callId: callId)
        }
    }

    /// Tear down a call ended remotely. Returns true if a known call was actually dismissed,
    /// so a VoIP `call.end` push can tell whether it still needs to satisfy `mustReport`.
    @discardableResult
    func handleRemoteCallEnded(callId: String, reason: CXCallEndedReason = .remoteEnded) -> Bool {
        restorePersistedMapping(for: callId)
        guard activeCall?.id == callId || pendingInvites[callId] != nil || callIdToUUID[callId] != nil else {
            return false
        }
        finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 500_000_000, endReason: reason)
        return true
    }

    /// Satisfy PushKit's `mustReport` contract for a `call.end` push that arrived with no live
    /// call to dismiss (e.g. the invite push was missed): report a call to CallKit and end it
    /// immediately. Prevents app termination on iOS 26.4+; only ever runs in that rare edge case.
    func reportEndedForCompliance(callId: String, invite: SocketService.CallInvite? = nil, completion: (() -> Void)? = nil) {
        let uuid = uuid(for: callId)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(
            type: .generic,
            value: invite?.displayTitle ?? pendingInvites[callId]?.fromDisplayName ?? "Call"
        )
        recentlyEndedCallIds.insert(callId)
        APIClient.mobileDiagnostic(event: "callkit.reportEndedForCompliance", callId: callId)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            Task { @MainActor in
                guard let self else { completion?(); return }
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                self.clear(callId)
                completion?()
            }
        }
    }

    /// A 1:1 peer's 60s reconnect grace window expired — they never came back, the call is
    /// over. Media was connected, so the server notify is an `end` (outcome completed).
    func handlePeerGraceExpired(callId: String) {
        guard activeCall?.id == callId else { return }
        APIClient.mobileDiagnostic(event: "callkit.peerGraceExpired.end", callId: callId)
        finishCall(callId: callId, status: "Ended", notifyServer: true, dismissAfter: 500_000_000)
    }

    /// The local rejoin loop exhausted its ~60s budget without getting back into the room.
    func handleRejoinGaveUp(callId: String) {
        guard activeCall?.id == callId else { return }
        APIClient.mobileDiagnostic(event: "callkit.rejoinGaveUp.end", callId: callId)
        finishCall(callId: callId, status: "Call ended", notifyServer: true, dismissAfter: 500_000_000)
    }

}

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "callkit.provider.reset", callId: activeCall?.id)
            Ringback.shared.stop()
            cancelAllRingTimeouts()
            if let call = activeCall {
                let wasConnected = isMediaConnected
                recentlyEndedCallIds.insert(call.id)
                playEndHaptic(call.id)
                await finishCallOnServer(callId: call.id, wasOutgoing: call.isOutgoing, wasConnected: wasConnected)
                clear(call.id)
            }
            // A held (call-waiting) call is torn down too — the whole provider is resetting.
            if let held = CallService.shared.heldCall {
                recentlyEndedCallIds.insert(held.id)
                await finishCallOnServer(callId: held.id, wasOutgoing: held.isOutgoing, wasConnected: true)
                clear(held.id)
            }
            CallService.shared.clearHeld()
            heldViaCallKit.removeAll()
            activeCall = nil
            await CallService.shared.leave()
            CallActivityController.end()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "callkit.answer.enter", detail: action.uuid.uuidString)
            guard let callId = callId(for: action.uuid) else {
                APIClient.mobileDiagnostic(event: "callkit.answer.missingCallId", detail: action.uuid.uuidString)
                action.fail()
                return
            }
            APIClient.mobileDiagnostic(event: "callkit.answer.fulfill", callId: callId)
            // M4: configure the call audio category/mode SYNCHRONOUSLY before fulfilling. On a
            // slow (background/cold) answer, CallKit can fire didActivate during the joinToken
            // round-trip below — if the session is still on ChatAudio's category from a voice
            // note, the call comes up with no/wrong audio. The kind is known from the pending
            // invite; CallService.join() re-applies this same configuration idempotently once
            // media is up. We only set the category (LiveKit/CallKit own activation).
            let answeringVideo = (pendingInvites[callId]?.kind ?? "AUDIO") == "VIDEO"
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: answeringVideo ? .videoChat : .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
            )
            action.fulfill()
            // Answering a call while another is active is one of two things:
            //  • "Hold & Accept" — CallKit already reported CXSetHeldCallAction on our current
            //    call, so keep it as the held call. Its LiveKit room is torn down when we join
            //    the new call below (single room at a time); it's rejoined when the new call ends.
            //  • "End & Accept" (or an unrelated overlap, e.g. our own outgoing call) — no hold
            //    was reported, so give the other call up entirely so it can't linger ringing.
            if let other = activeCall, other.id != callId {
                if heldViaCallKit.contains(other.id), !recentlyEndedCallIds.contains(other.id) {
                    APIClient.mobileDiagnostic(event: "callkit.answer.holdOther", callId: other.id, detail: callId)
                    CallService.shared.markHeld(other)
                } else {
                    APIClient.mobileDiagnostic(event: "callkit.answer.endOther", callId: other.id, detail: callId)
                    endAbandonedCall(other.id)
                }
            }
            statusText = "Connecting..."
            do {
                // Everything needed to join comes from the token response, so answering
                // works even if the original invite is no longer in memory.
                print("CallKit answer: requesting join token for \(callId)")
                APIClient.mobileDiagnostic(event: "callkit.answer.token.start", callId: callId)
                let session = try await APIClient.shared.joinToken(callId: callId)
                APIClient.mobileDiagnostic(event: "callkit.answer.token.ok", callId: callId)
                let invite = pendingInvites[callId]
                let kind = invite?.kind ?? session.kind ?? "AUDIO"
                let isVideo = kind == "VIDEO"
                let peerName = invite?.displayTitle ?? "Call"
                activeCall = ActiveCall(
                    id: callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
                    token: session.token, kind: kind, peerName: peerName,
                    peerId: invite?.fromUserId, peerAvatarUrl: nil, isOutgoing: false,
                    conversationId: invite?.conversationId, isGroup: invite?.isGroup ?? false
                )
                APIClient.mobileDiagnostic(event: "callkit.answer.livekit.start", callId: callId)
                try await CallService.shared.join(
                    callId: callId,
                    url: session.livekitUrl,
                    token: session.token,
                    video: isVideo
                )
                // The caller may have hung up while join() was in flight. handleRemoteCallEnded
                // already set activeCall = nil and scheduled leave() — bail out here so we don't
                // re-surface a Connected state on a call that's already being torn down.
                guard !recentlyEndedCallIds.contains(callId) else {
                    APIClient.mobileDiagnostic(event: "callkit.answer.endedDuringConnect", callId: callId)
                    return
                }
                _ = try await APIClient.shared.mediaJoined(callId: callId)
                statusText = "Connected"
                markConnected()
                APIClient.mobileDiagnostic(event: "callkit.answer.livekit.ok", callId: callId)
                CallActivityController.start(peerName: peerName, isVideo: isVideo)
                CallActivityController.update(status: "Connected", muted: false, isVideo: isVideo)
                if invite?.isGroup != true {
                    CallIntents.donate(peerName: peerName, peerId: invite?.fromUserId, isVideo: isVideo)
                }
            } catch {
                print("CallKit answer failed for \(callId): \(error)")
                // If the call was torn down while we were still connecting (caller hung up
                // fast, or the peer dropped), the join throws "Cancelled"/"disconnected" —
                // that's not a real failure, so clean up quietly without a misleading
                // "Call failed" banner or a spurious decline back to the (gone) caller.
                if recentlyEndedCallIds.contains(callId) {
                    APIClient.mobileDiagnostic(event: "callkit.answer.cancelledDuringJoin", callId: callId)
                    finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 0)
                } else {
                    APIClient.mobileDiagnostic(
                        event: "callkit.answer.failed",
                        callId: callId,
                        detail: String(describing: error)
                    )
                    _ = try? await APIClient.shared.failCall(callId: callId)
                    finishCall(callId: callId, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = activeCall else { action.fail(); return }
            action.fulfill()
            // Outgoing calls must also be holdable (see reportIncoming's supportsHolding).
            let holdUpdate = CXCallUpdate()
            holdUpdate.supportsHolding = true
            provider.reportCall(with: action.uuid, updated: holdUpdate)
            // Tell CallKit the outgoing call is connecting. Reporting the outgoing-call lifecycle is
            // what makes the system reliably activate the call's audio session (→ provider
            // didActivate → publishMicIfReady publishes the mic). Without it, didActivate can be
            // skipped or arrive late on an outgoing call, leaving the mic unpublished while playout
            // still works — the "I hear them but they can't hear me" one-way-audio bug.
            provider.reportOutgoingCall(with: action.uuid, startedConnectingAt: Date())
            do {
                APIClient.mobileDiagnostic(event: "callkit.start.fulfill", callId: call.id)
                try await CallService.shared.join(
                    callId: call.id,
                    url: call.livekitUrl,
                    token: call.token,
                    video: call.isVideo
                )
                _ = try await APIClient.shared.mediaJoined(callId: call.id)
            } catch {
                _ = try? await APIClient.shared.cancelCall(callId: call.id)
                finishCall(callId: call.id, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
                return
            }
            // Our media is up. Report the call connected so CallKit activates the audio session now
            // (firing provider(didActivate:), which publishes the mic) rather than leaving it to an
            // unreliable implicit activation. The in-app status stays "Calling…" until the callee
            // actually answers (handlePeerAccepted), so the on-screen UI is unaffected.
            provider.reportOutgoingCall(with: action.uuid, connectedAt: Date())
            // We're connected to the room but still waiting for the callee to answer — play the
            // outgoing ringback until they do (handlePeerAccepted stops it). A late-join of an
            // ongoing call ("Connecting...", via joinOngoing) is live immediately: no ringback.
            if statusText == "Calling..." { Ringback.shared.start() }
            if statusText == "Connecting..." { statusText = "Connected"; markConnected() }
            CallActivityController.start(peerName: call.peerName, isVideo: call.isVideo)
            CallActivityController.update(status: statusText, muted: false, isVideo: call.isVideo)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            Ringback.shared.stop()
            // Resolve the ended call from the action's UUID FIRST. Using `activeCall` first would
            // misroute when a second call is ringing/held over an active one — e.g. declining the
            // 2nd would end the 1st. Fall back to activeCall only when the UUID can't be resolved.
            let id = callId(for: action.uuid) ?? activeCall?.id
            APIClient.mobileDiagnostic(event: "callkit.end.enter", callId: id, detail: action.uuid.uuidString)
            // Fulfill immediately — CallKit enforces a short deadline on this action and will
            // call providerDidReset (killing all calls) if we don't respond fast enough. The
            // actual async teardown (server notify, LiveKit disconnect) happens after.
            action.fulfill()
            // Ending the HELD (call-waiting) call from the CallKit UI: tear it down on its own so
            // the ACTIVE call's media keeps running.
            if let id, id != activeCall?.id, id == CallService.shared.heldCall?.id {
                // A held call was always a connected call, so this is a genuine end.
                endHeldCall(id, notifyServer: true)
                return
            }
            let endedActiveCall = id == nil || id == activeCall?.id
            if let id {
                recentlyEndedCallIds.insert(id)
                playEndHaptic(id)
                // A ringing invite being dismissed — including a 2nd incoming call declined while a
                // first call is active (id != the active call) — is a decline, not an end.
                let isRingingInvite = pendingInvites[id] != nil && activeCall?.id != id
                let wasOutgoing = activeCall?.id == id && activeCall?.isOutgoing == true
                let wasConnected = activeCall?.id == id && isMediaConnected
                // Registered as serverTeardown so a fast follow-up call awaits it instead of
                // racing it into a 409 call_exists (the dead-call-button-after-hang-up bug).
                let teardown = Task {
                    if isRingingInvite {
                        _ = try? await APIClient.shared.declineCall(callId: id)
                    } else if !wasConnected {
                        if wasOutgoing {
                            _ = try? await APIClient.shared.cancelCall(callId: id)
                        } else {
                            _ = try? await APIClient.shared.declineCall(callId: id)
                        }
                    } else {
                        _ = try? await APIClient.shared.endCall(callId: id)
                    }
                }
                serverTeardown = teardown
                _ = await teardown.value
                endSystemCall(callId: id)
                clear(id)
            }
            // Only tear down the shared media session if we actually ended the ACTIVE call — a
            // declined 2nd ringing call must leave the first call's media untouched.
            if endedActiveCall {
                await CallService.shared.leave()
                CallActivityController.end()
                activeCall = nil
                // The active call ended — bring back any call we were holding for call-waiting.
                resumeHeldCallIfNeeded(endedCallId: id)
            }
        }
    }

    /// CallKit holds/unholds the call — issued automatically when the user answers a native
    /// phone call mid-Klic-call (and again when that call ends). On hold: mute the mic and
    /// gate the audio engine off (CallService.setHold reuses the existing engine/mic
    /// plumbing); on unhold: restore both and go back to Connected.
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor in
            let heldId = callId(for: action.callUUID)
            APIClient.mobileDiagnostic(
                event: "callkit.hold",
                callId: heldId,
                detail: action.isOnHold ? "on" : "off"
            )
            if action.isOnHold {
                // Record synchronously (before any await) so the answer handler that follows a
                // "Hold & Accept" can tell this apart from an "End & Accept".
                if let heldId { heldViaCallKit.insert(heldId) }
                await CallService.shared.setHold(true)
                if isMediaConnected { statusText = "On Hold" }
            } else {
                if let heldId { heldViaCallKit.remove(heldId) }
                // A call-waiting call being taken off hold: its LiveKit room was discarded when we
                // answered the interrupting call, so rejoin it from scratch rather than un-muting a
                // room we no longer have. (Idempotent with the end-path resume.)
                if let heldId, heldId == CallService.shared.heldCall?.id {
                    action.fulfill()
                    resumeHeldCall()
                    return
                }
                await CallService.shared.setHold(false)
                if statusText == "On Hold" { statusText = "Connected" }
            }
            CallActivityController.update(
                status: statusText,
                muted: !CallService.shared.micEnabled,
                isVideo: activeCall?.isVideo ?? false
            )
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            await CallService.shared.setMic(enabled: !action.isMuted)
            CallActivityController.update(
                status: "Connected", muted: action.isMuted, isVideo: activeCall?.isVideo ?? false
            )
            action.fulfill()
        }
    }

    // CallKit owns activation/deactivation of the call's audio session. LiveKit's audio engine is
    // gated OFF during join until this fires, so it can't activate the session ahead of CallKit
    // (the locked-screen "Audio Session Error 802" / running-timer-but-no-audio bug). On
    // didActivate we enable the engine on the now-active session; on didDeactivate we gate it off.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        APIClient.mobileDiagnostic(event: "callkit.audio.didActivate")
        Task { @MainActor in CallService.shared.activateAudioSession() }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        APIClient.mobileDiagnostic(event: "callkit.audio.didDeactivate")
        Task { @MainActor in CallService.shared.deactivateAudioSession() }
    }
}
