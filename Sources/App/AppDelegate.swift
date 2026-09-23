import UIKit
import PushKit
import UserNotifications

/// Handles push registration: APNs (message alerts) and PushKit VoIP (incoming calls →
/// reported to CallKit immediately so the phone rings even when the app is killed).
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var voipRegistry: PKPushRegistry?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle")?.load()
        #endif
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        DispatchQueue.main.async { application.registerForRemoteNotifications() }

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry

        // Arm system PiP whenever a call has live remote video, so backgrounding the app
        // mid-video-call pops the remote feed into the floating system window.
        MainActor.assumeIsolated { CallPictureInPicture.shared.start() }

        // Launch beacon: distinguishes "iOS never launched the killed app for a VoIP push"
        // (no beacon in the server journal) from "launched but died in the push path"
        // (beacon present, pushkit.* absent) when diagnosing missed rings.
        let state = application.applicationState
        APIClient.mobileDiagnostic(
            event: "app.launch",
            detail: state == .background ? "background" : state == .inactive ? "inactive" : "active"
        )
        return true
    }

    // APNs (alert) token
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in
            DeviceRegistrar.apnsToken = token.hexString
            DeviceRegistrar.sync()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }
}

// MARK: - PushKit (VoIP) → CallKit

extension AppDelegate: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            DeviceRegistrar.voipToken = pushCredentials.token.hexString
            DeviceRegistrar.sync()
        }
    }

    // Legacy delegate (iOS < 26.4): no metadata, so a VoIP push must always be reported.
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        handleVoIPPush(payload.dictionaryPayload, mustReport: true, completion: completion)
    }

    // iOS 26.4+: the system tells us via `mustReport` whether this push must be reported to
    // CallKit. It's NO when we're foreground, already on a call, or the push is stale — cases
    // where the live socket handles delivery (invite) or there's nothing to dismiss (end), so
    // we can skip reporting and avoid both a spurious ring and the contract violation.
    @available(iOS 26.4, *)
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingVoIPPushWith payload: PKPushPayload,
        metadata: PKVoIPPushMetadata,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        handleVoIPPush(payload.dictionaryPayload, mustReport: metadata.mustReport, completion: completion)
    }

    private func handleVoIPPush(
        _ d: [AnyHashable: Any],
        mustReport: Bool,
        completion: @escaping () -> Void
    ) {
        // First-touch beacon, before any guard — proves the push reached the process.
        APIClient.mobileDiagnostic(
            event: "pushkit.push",
            callId: d["callId"] as? String,
            detail: "type=\(d["type"] as? String ?? "invite") mustReport=\(mustReport)"
        )
        if d["type"] as? String == "call.end" {
            let callId = d["callId"] as? String ?? ""
            APIClient.mobileDiagnostic(event: "pushkit.callEnd.received", callId: callId)
            MainActor.assumeIsolated {
                // Dismiss the live ring/call this teardown refers to, if we're showing one.
                CallKitManager.shared.handleRemoteCallEnded(callId: callId)
                // PushKit's must-report contract requires reportNewIncomingCall for EVERY delivered
                // VoIP push. Dismissing a live call via reportCall(endedAt:) does NOT satisfy it —
                // that reports an END, not a NEW incoming call — so we report-then-end for
                // compliance whenever the system says this push must be reported, REGARDLESS of
                // whether we also dismissed a live ring. Skipping it terminates the app on
                // iOS < 26.4 (whose handler passes mustReport unconditionally) and eventually makes
                // iOS stop waking the app for VoIP pushes — a cause of an asleep/killed iPhone
                // silently never ringing. On iOS 26.4+ the system sets mustReport = false for a
                // stale/foreground end push, so this compliance flash is skipped there.
                if mustReport {
                    CallKitManager.shared.reportEndedForCompliance(callId: callId)
                }
            }
            completion()
            return
        }
        let invite = SocketService.CallInvite(
            id: d["callId"] as? String ?? "",
            conversationId: d["conversationId"] as? String ?? "",
            roomName: d["roomName"] as? String ?? "",
            livekitUrl: d["livekitUrl"] as? String ?? "",
            kind: d["kind"] as? String ?? "AUDIO",
            fromDisplayName: d["fromName"] as? String ?? "Incoming call",
            fromUserId: d["fromUserId"] as? String,
            conversationType: d["conversationType"] as? String,
            conversationTitle: d["conversationTitle"] as? String,
            // Push data values may arrive stringified depending on the transport.
            participantCount: d["participantCount"] as? Int ?? (d["participantCount"] as? String).flatMap(Int.init)
        )
        MainActor.assumeIsolated {
            guard mustReport else {
                APIClient.mobileDiagnostic(event: "pushkit.skippedNotMustReport", callId: invite.id)
                completion()
                return
            }
            // M-5: ringer policy on the push path (mirrors the socket handler in
            // SocketService) — a per-chat calls-mute suppresses the ring on THIS device
            // only; the server still delivers the VoIP invite. A delivered VoIP push must
            // still be reported (H2 must-report contract), so suppress via report-then-end
            // on a throwaway UUID rather than skipping. Silenced-unknown-caller invites
            // never ride the VoIP transport — the server sends those as alert pushes — so
            // the per-chat mute is the only policy check the push path needs.
            if !invite.conversationId.isEmpty, ChatLocalPrefs.callsMuted(invite.conversationId) {
                APIClient.mobileDiagnostic(event: "pushkit.skippedMutedChat", callId: invite.id)
                CallKitManager.shared.reportEndedForCompliance(
                    callId: invite.id, invite: invite, completion: completion
                )
                return
            }
            APIClient.mobileDiagnostic(event: "pushkit.received", callId: invite.id, detail: invite.kind)
            // iOS requires reporting the call synchronously here (the registry runs on .main),
            // otherwise the app can be terminated and future VoIP pushes blocked.
            CallKitManager.shared.reportIncoming(invite, fromPushKit: true, completion: completion)
        }
    }

    // L-6: the system invalidated our VoIP token (VoIP entitlement/notification state
    // changed, registry torn down). There is no server endpoint that unregisters a single
    // token — POST /me/devices merges tokens onto the install's row and never clears one —
    // so drop it locally so later sync()s stop re-sending the dead token, and leave retiring
    // the stale row to the server's bounced-push pruning.
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        APIClient.mobileDiagnostic(event: "pushkit.tokenInvalidated")
        Task { @MainActor in DeviceRegistrar.voipToken = nil }
    }
}

// MARK: - Foreground message banners

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Foreground banner/sound path honors the notification prefs (CALLS.md §8.4):
    /// per-chat mutes suppress the banner entirely; a per-chat alert tone replaces
    /// the system sound. (The delivered push's own sound stays "default" — APNs
    /// sound is chosen server-side, so per-chat tones apply in-app only.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        guard let conversationId = userInfo["conversationId"] as? String else {
            return [.banner, .sound]
        }
        if ChatLocalPrefs.messagesMuted(conversationId) {
            return []
        }
        if let tone = ChatLocalPrefs.alertTone(conversationId) {
            KlicTone.play(file: tone)
            return [.banner]
        }
        return [.banner, .sound]
    }
}
