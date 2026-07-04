import SwiftUI
import LiveKit
import Inject

struct CallView: View {
    @ObserveInjection var inject
    let call: CallKitManager.ActiveCall

    @EnvironmentObject private var session: AppSession
    @ObservedObject private var service = CallService.shared
    @ObservedObject private var callKit = CallKitManager.shared

    /// When true the local camera is the full-screen feed and the remote becomes the small card
    /// (tap the card or its expand button to swap, WhatsApp-style).
    @State private var localFullscreen = false
    /// Committed center of the draggable card (nil = its default top-right corner).
    @State private var cardCenter: CGPoint? = nil
    @GestureState private var dragTranslation = CGSize.zero

    private let cardSize = CGSize(width: 110, height: 160)

    /// 2+ remotes → group grid; 0–1 remote → today's 1:1 layout (fullscreen feed + swap card).
    private var isGrid: Bool { service.participants.count >= 2 }

    var body: some View {
        GeometryReader { geo in
            // Pick which feed is full-screen and which rides in the draggable card. The
            // fullscreen surface only ever carries video when the REMOTE side has video
            // (§7.6) — my own camera alone renders as the small preview card over the
            // themed avatar layout, never as the fullscreen "video look".
            let local = service.cameraEnabled ? service.localVideoTrack : nil
            let remote = isGrid ? nil : service.remoteVideoTrack
            let primaryIsLocal = localFullscreen && local != nil && remote != nil
            let primaryTrack = primaryIsLocal ? local : remote
            let secondaryTrack = primaryIsLocal ? remote : local

            ZStack {
                KlicColor.background.ignoresSafeArea()

                if isGrid {
                    participantGrid
                } else if let primaryTrack {
                    CallVideoView(track: primaryTrack).ignoresSafeArea()
                } else {
                    avatar
                }

                VStack {
                    header
                    Spacer()
                    controls
                }
                .padding(.vertical, 56)

                // Minimize: collapse the call screen into the floating root overlay so the
                // rest of the app is browsable mid-call. UI-only — media keeps running.
                VStack {
                    HStack {
                        Button {
                            callKit.callMinimized = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(videoLook ? Color.white : KlicColor.textPrimary)
                                .frame(width: 38, height: 38)
                                .background(
                                    videoLook ? Color.black.opacity(0.35) : KlicColor.surfaceRaised,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)

                // Draggable picture-in-picture card — 1:1 layout ONLY (§17.1: in the group
                // grid my feed is a regular tile instead, so no floating card there). It
                // holds the secondary feed: swap on tap when both sides have video, my lone
                // camera preview otherwise.
                if !isGrid, let secondaryTrack {
                    pipCard(track: secondaryTrack, geo: geo, allowSwap: local != nil && remote != nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Don't let the screen dim/lock while the call UI is up (matches Android's keepScreenOn).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .enableInjection()
    }

    /// Group-call grid (§17.1): every participant gets a tile — remotes first in their
    /// existing order, ME last (mirrored selfie feed when my camera is on, the same
    /// avatar/mute chrome as remote tiles when it's off). The grid NEVER scrolls: all
    /// tiles always fit between the header and the controls, shrinking as the call grows.
    private var participantGrid: some View {
        CallTileGrid(tiles: gridTiles)
            .padding(.horizontal, 12)
            .padding(.top, 140)
            .padding(.bottom, 170)
    }

    private var gridTiles: [CallGridTile] {
        var tiles = service.participants.map(CallGridTile.init(remote:))
        tiles.append(CallGridTile(
            id: CallGridTile.localTileId,
            label: "You",
            avatarUserId: session.currentUser?.id,
            avatarName: session.currentUser?.displayName ?? "You",
            videoTrack: service.cameraEnabled ? service.localVideoTrack : nil,
            micMuted: !service.micEnabled,
            isSpeaking: service.localIsSpeaking,
            isInGrace: false
        ))
        return tiles
    }

    /// Draggable, side-snapping PiP card; `allowSwap` enables the 1:1 tap-to-swap behavior.
    /// The live drag renders as a pure offset from the committed position (no per-frame
    /// state writes that relayout the screen); release commits where the finger left off
    /// and springs to the edge the flick was headed for (predicted end point).
    private func pipCard(track: VideoTrack, geo: GeometryProxy, allowSwap: Bool) -> some View {
        let defaultCenter = CGPoint(x: geo.size.width - cardSize.width / 2 - 16,
                                    y: cardSize.height / 2 + 80)
        let center = cardCenter ?? defaultCenter
        return CallVideoView(track: track)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if allowSwap {
                    Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }
            .shadow(radius: 8)
            .position(center)
            .offset(dragTranslation)
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        // Commit exactly where the finger let go, unanimated — the gesture
                        // state resets to .zero in this same update, so the card doesn't
                        // jump — then spring to the snapped spot on the next runloop turn.
                        let release = CGPoint(x: center.x + value.translation.width,
                                              y: center.y + value.translation.height)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { cardCenter = release }

                        let predicted = CGPoint(x: center.x + value.predictedEndTranslation.width,
                                                y: center.y + value.predictedEndTranslation.height)
                        // Snap to the side the flick was headed for, clamp vertically.
                        var target = predicted
                        let halfW = cardSize.width / 2 + 16
                        target.x = predicted.x < geo.size.width / 2 ? halfW : geo.size.width - halfW
                        target.y = min(max(target.y, cardSize.height / 2 + 70),
                                       geo.size.height - cardSize.height / 2 - 70)
                        Task { @MainActor in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                cardCenter = target
                            }
                        }
                    }
            )
            .onTapGesture { if allowSwap { withAnimation { localFullscreen.toggle() } } }
    }

    private var avatar: some View {
        VStack(spacing: 14) {
            AvatarView(
                url: call.peerAvatarUrl ?? call.peerId.map { APIClient.avatarURL(forUserId: $0) },
                name: call.peerName,
                size: 120
            )
        }
    }

    // §7.6: with the remote video fullscreen the header disappears entirely (controls
    // remain); an "On Hold" pill still surfaces over the video. Everything else — voice
    // call, or the peer's camera off even while MY camera is on — gets the standard
    // themed layout: name + status pill in theme colors, never white-on-nothing.
    @ViewBuilder private var header: some View {
        if videoLook {
            if service.isOnHold {
                Text("On Hold")
                    .font(KlicFont.caption(13))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
            }
        } else {
            VStack(spacing: 8) {
                Text(call.peerName)
                    .font(KlicFont.title())
                    .foregroundStyle(KlicColor.textPrimary)
                Text(statusLine)
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(KlicColor.surfaceRaised, in: Capsule())
            }
        }
    }

    /// §9.7: alone in a connected group room = honest "Waiting for others…", never a
    /// fake ongoing peer.
    private var statusLine: String {
        if call.isGroup, callKit.statusText == "Connected", service.participants.isEmpty {
            return "Waiting for others…"
        }
        return callKit.statusText
    }

    private var controls: some View {
        // With the camera on, the switch-camera button joins the row (5 buttons) —
        // shrink sizes/spacing so everything still fits on narrow phones.
        let compact = service.cameraEnabled
        let buttonSize: CGFloat = compact ? 54 : 64
        let endSize: CGFloat = compact ? 64 : 72
        return HStack(spacing: compact ? 14 : 24) {
            circleButton(service.micEnabled ? "mic.fill" : "mic.slash.fill", size: buttonSize) {
                Task {
                    await service.toggleMic()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: hasAnyVideo
                    )
                }
            }
            // Speaker / earpiece toggle — shown on voice AND video calls (video auto-routes to
            // the speaker, but the user can still force the earpiece; the automatic route only
            // re-applies when the video state next flips).
            circleButton(
                service.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                fill: service.speakerOn ? KlicColor.primary : KlicColor.surfaceRaised,
                iconColor: service.speakerOn ? KlicColor.onPrimary : KlicColor.textPrimary,
                size: buttonSize
            ) {
                service.toggleSpeaker()
            }
            circleButton("phone.down.fill", fill: KlicColor.danger, iconColor: KlicColor.onPrimary, size: endSize) {
                CallKitManager.shared.requestEnd()
            }
            circleButton(service.cameraEnabled ? "video.fill" : "video.slash.fill", size: buttonSize) {
                Task {
                    await service.toggleCamera()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: hasAnyVideo
                    )
                }
            }
            if service.cameraEnabled {
                circleButton("arrow.triangle.2.circlepath.camera", size: buttonSize) {
                    Task { await service.switchCamera() }
                }
            }
        }
    }

    // Circular in-call control using a native SF Symbol.
    private func circleButton(
        _ systemName: String,
        fill: Color = KlicColor.surfaceRaised,
        iconColor: Color = KlicColor.textPrimary,
        size: CGFloat = 64,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// The "video-call look" (white chrome over the fullscreen feed) keys on REMOTE video
    /// being rendered fullscreen — NOT on the local camera state (§7.6). In the group grid
    /// the background is themed, so the themed chrome applies there too.
    private var videoLook: Bool {
        !isGrid && service.remoteVideoTrack != nil
    }

    /// Whether any video is on screen at all — only used for the Live Activity's video flag.
    private var hasAnyVideo: Bool {
        service.cameraEnabled || service.localVideoTrack != nil || service.remoteVideoTrack != nil
    }
}

/// One tile of the group-call grid — a remote participant, or my own local feed. Both
/// render the exact same chrome: name label, mute badge, camera-off avatar, speaking glow.
struct CallGridTile: Identifiable {
    static let localTileId = "local"

    let id: String
    let label: String          // display label ("You" for the local tile)
    let avatarUserId: String?  // avatar source for the camera-off state
    let avatarName: String     // initials fallback for the avatar
    var videoTrack: VideoTrack?
    var micMuted: Bool
    var isSpeaking: Bool
    var isInGrace: Bool

    init(
        id: String, label: String, avatarUserId: String?, avatarName: String,
        videoTrack: VideoTrack?, micMuted: Bool, isSpeaking: Bool, isInGrace: Bool
    ) {
        self.id = id
        self.label = label
        self.avatarUserId = avatarUserId
        self.avatarName = avatarName
        self.videoTrack = videoTrack
        self.micMuted = micMuted
        self.isSpeaking = isSpeaking
        self.isInGrace = isInGrace
    }

    init(remote p: CallService.RemoteCallParticipant) {
        self.init(
            id: p.id, label: p.name, avatarUserId: p.id, avatarName: p.name,
            videoTrack: p.videoTrack, micMuted: p.micMuted,
            isSpeaking: p.isSpeaking, isInGrace: p.isInGrace
        )
    }
}

/// Non-scrolling, Zoom-style fitting grid (§17.1): the row/column split comes from the
/// tile count — 2 tiles stack 1×2 full-width, 3–4 flow 2×2, 5–6 → 2×3, 7–9 → 3×3 — and
/// every tile's size is computed so the whole call always fits the available bounds.
/// An odd last row centers its tiles at the same size as everyone else's.
struct CallTileGrid: View {
    let tiles: [CallGridTile]

    private let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let count = max(tiles.count, 1)
            let columns = count <= 2 ? 1 : (count <= 6 ? 2 : 3)
            let rows = (count + columns - 1) / columns
            let tileWidth = (geo.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let tileHeight = (geo.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(rowTiles(row, columns: columns)) { tile in
                            ParticipantTile(tile: tile)
                                .frame(width: tileWidth, height: tileHeight)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func rowTiles(_ row: Int, columns: Int) -> [CallGridTile] {
        let start = row * columns
        return Array(tiles[start..<min(start + columns, tiles.count)])
    }
}

/// One tile in the group-call grid: video, or an avatar + name fallback, with a mute badge.
/// The active speaker's tile carries an accent glow that appears live and lingers ~400ms
/// after they stop, so brief speech pauses don't flicker (works in the avatar state too).
/// A participant in their reconnect grace window renders dimmed with a "Reconnecting…" label.
private struct ParticipantTile: View {
    let tile: CallGridTile

    @State private var speakingGlow = false
    @State private var glowFadeTask: Task<Void, Never>?

    private var showsSpeaking: Bool { tile.isSpeaking && !tile.isInGrace }

    var body: some View {
        ZStack {
            KlicColor.surfaceRaised
            if let track = tile.videoTrack, !tile.isInGrace {
                CallVideoView(track: track)
            } else {
                AvatarView(
                    url: tile.avatarUserId.map { APIClient.avatarURL(forUserId: $0) },
                    name: tile.avatarName,
                    size: 64
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 5) {
                Text(tile.label)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if tile.micMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
        }
        .overlay {
            if tile.isInGrace {
                ZStack {
                    Color.black.opacity(0.55)
                    Text("Reconnecting…")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    speakingGlow ? KlicColor.primary : Color.white.opacity(0.15),
                    lineWidth: speakingGlow ? 2.5 : 1
                )
        )
        .shadow(
            color: speakingGlow ? KlicColor.primary.opacity(0.5) : .clear,
            radius: speakingGlow ? 9 : 0
        )
        .onAppear { speakingGlow = showsSpeaking }
        .onChange(of: showsSpeaking) { _, speaking in
            glowFadeTask?.cancel()
            glowFadeTask = nil
            if speaking {
                withAnimation(.easeIn(duration: 0.15)) { speakingGlow = true }
            } else {
                // Linger before fading so natural mid-sentence pauses don't flicker the glow.
                glowFadeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.35)) { speakingGlow = false }
                }
            }
        }
        .onDisappear { glowFadeTask?.cancel() }
    }
}

#if DEBUG
/// Simulator harness for eyeballing the call layouts, where live group media isn't
/// available: launch with `-callLayoutDemo grid:N` to render the real CallView over a
/// seeded group call with N total tiles (mine last; one remote speaking, one muted,
/// the largest layout also gets a reconnecting tile), or `-callLayoutDemo oneToOne`
/// for the untouched 1:1 screen. Debug builds only; inert without the argument.
struct CallLayoutDemoView: View {
    static var requestedMode: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-callLayoutDemo"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    static var isRequested: Bool { requestedMode != nil }

    let mode: String

    init(mode: String? = nil) {
        self.mode = mode ?? Self.requestedMode ?? "grid:3"
    }

    private var isGroup: Bool { mode.hasPrefix("grid:") }

    private var demoCall: CallKitManager.ActiveCall {
        CallKitManager.ActiveCall(
            id: "layout-demo", roomName: "layout-demo", livekitUrl: "", token: "",
            kind: "AUDIO", peerName: isGroup ? "Design Crew" : "Alex Rivera",
            peerId: nil, peerAvatarUrl: nil, isOutgoing: true,
            conversationId: nil, isGroup: isGroup
        )
    }

    var body: some View {
        CallView(call: demoCall)
            .environmentObject(AppSession())
            .onAppear { seed() }
    }

    private func seed() {
        guard isGroup else { return }
        let total = max(Int(mode.dropFirst("grid:".count)) ?? 3, 3)
        let names = ["Alice", "Ben", "Chloe", "Dana", "Eli", "Fiona", "Gus", "Hana"]
        let remotes = (0..<(total - 1)).map { i in
            CallService.RemoteCallParticipant(
                id: "demo-\(i)",
                name: names[i % names.count],
                videoTrack: nil,
                micMuted: i == 1,                       // one muted badge
                isSpeaking: i == 0,                     // one active speaker
                isInGrace: total >= 6 && i == total - 2 // one reconnecting tile on big grids
            )
        }
        CallService.shared.debugSeedParticipants(remotes)
    }
}
#endif
