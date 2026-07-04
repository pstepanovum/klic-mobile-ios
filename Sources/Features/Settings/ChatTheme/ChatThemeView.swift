import SwiftUI
import Inject

/// Settings → Chat theme (§12.3): the GLOBAL theme editor — live mini-chat preview,
/// pattern grid, pattern opacity, gradient presets + intensity, own-bubble color, Reset.
struct ChatThemeView: View {
    @ObserveInjection var inject
    @ObservedObject private var theme = ChatThemeStore.shared

    var body: some View {
        ChatThemeEditor(
            config: Binding(
                get: { theme.globalConfig },
                set: { theme.globalConfig = $0 }
            ),
            resetTitle: String(localized: "Reset theme"),
            onReset: { theme.reset() }
        )
        .navigationTitle("Chat theme")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }
}

/// §14.3: the SAME theme UI scoped to one conversation. DMs store a LOCAL override
/// (per conversation id, over the global theme); groups share the theme through the
/// server (admin-only edit; PATCH /conversations/:id {theme}), so every member
/// re-renders live. "Use default" resets to the global theme (null on the server).
struct ConversationThemeView: View {
    @ObserveInjection var inject
    let conversationId: String
    let isGroup: Bool

    @ObservedObject private var theme = ChatThemeStore.shared
    @State private var config: ChatThemeConfig = ChatThemeConfig()
    @State private var loadedInitial = false
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        ChatThemeEditor(
            config: Binding(
                get: { config },
                set: { apply($0) }
            ),
            resetTitle: String(localized: "Use default theme"),
            footnote: isGroup
                ? String(localized: "This theme is shared — every member of the group sees it.")
                : String(localized: "This theme applies to this chat only, on this device."),
            errorText: errorText,
            onReset: { resetToDefault() }
        )
        .navigationTitle("Chat theme")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loadedInitial else { return }
            loadedInitial = true
            config = theme.resolvedConfig(for: conversationId)
        }
        .enableInjection()
    }

    private func apply(_ newConfig: ChatThemeConfig) {
        config = newConfig.sanitized()
        errorText = nil
        if isGroup {
            // Optimistic local render; the PATCH (debounced across slider drags)
            // makes it authoritative and fans out to every member.
            theme.setGroupTheme(config.payload, for: conversationId)
            scheduleGroupSave(config.payload)
        } else {
            theme.setOverride(config, for: conversationId)
        }
    }

    private func resetToDefault() {
        saveTask?.cancel()
        errorText = nil
        if isGroup {
            theme.setGroupTheme(nil, for: conversationId)
            saveTask = Task {
                do {
                    let updated = try await APIClient.shared.updateGroupTheme(conversationId: conversationId, theme: nil)
                    ChatThemeStore.shared.setGroupTheme(updated.theme, for: conversationId)
                    ChatCaches.groupDetails[conversationId] = updated
                } catch {
                    errorText = Self.describe(error)
                }
            }
        } else {
            theme.clearOverride(for: conversationId)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            config = isGroup ? theme.globalConfig : theme.resolvedConfig(for: conversationId)
        }
    }

    /// One PATCH per settle (sliders emit continuously) — 600ms debounce.
    private func scheduleGroupSave(_ payload: GroupThemePayload) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            do {
                let updated = try await APIClient.shared.updateGroupTheme(conversationId: conversationId, theme: payload)
                ChatThemeStore.shared.setGroupTheme(updated.theme, for: conversationId)
                ChatCaches.groupDetails[conversationId] = updated
            } catch {
                errorText = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError { return apiError.userMessage }
        return String(localized: "Couldn't save the theme right now.")
    }
}

// MARK: - Shared editor UI

/// The theme editing surface shared by the global page and the per-conversation page
/// (§14.3): everything operates on one bound `ChatThemeConfig`.
private struct ChatThemeEditor: View {
    @Binding var config: ChatThemeConfig
    let resetTitle: String
    var footnote: String? = nil
    var errorText: String? = nil
    let onReset: () -> Void

    // §13.1: a PROPER grid — uniform tile size/spacing/corner radius, two fixed
    // rows scrolling horizontally so the layout never jags.
    private static let patternTileSize: CGFloat = 72
    private static let patternTileSpacing: CGFloat = 10
    private static let patternTileRadius: CGFloat = 14
    private let patternRows = [
        GridItem(.fixed(patternTileSize), spacing: patternTileSpacing),
        GridItem(.fixed(patternTileSize), spacing: patternTileSpacing),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewCard
                patternCard
                gradientCard
                bubbleCard

                if let footnote {
                    Text(footnote)
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if let errorText {
                    Text(errorText)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.danger)
                        .multilineTextAlignment(.center)
                }

                PillButton(
                    title: resetTitle,
                    fill: KlicColor.surface,
                    textColor: KlicColor.danger
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { onReset() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(KlicColor.background.ignoresSafeArea())
    }

    // MARK: Live preview

    private var previewCard: some View {
        ZStack {
            ChatThemeBackground(config: config)
            VStack(alignment: .leading, spacing: 6) {
                previewBubble(String(localized: "Hey! Have you seen the new themes?"), mine: false)
                previewBubble(String(localized: "Yes — picking mine right now 🎨"), mine: true)
                previewBubble(String(localized: "Looks great!"), mine: false)
            }
            .padding(14)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func previewBubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .font(KlicFont.body(14))
                .foregroundStyle(mine ? KlicColor.onPrimary : KlicColor.textPrimary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(mine ? config.bubbleColor : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 40) }
        }
    }

    // MARK: Pattern

    private var patternCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background pattern")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: patternRows, spacing: Self.patternTileSpacing) {
                    ForEach(1...10, id: \.self) { id in
                        patternSwatch(id)
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pattern opacity")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text(verbatim: "\(Int((config.patternOpacity * 100).rounded()))%")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .monospacedDigit()
                }
                Slider(value: $config.patternOpacity, in: ChatThemeStore.patternOpacityRange)
                    .tint(KlicColor.primary)
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    /// §13.1 selection treatment: an accent-colored ring (2.5pt, slightly inset) plus
    /// a small checkmark badge; unselected tiles keep a hairline neutral border so
    /// tiles read as tiles in both light and dark themes.
    private func patternSwatch(_ id: Int) -> some View {
        let selected = config.patternId == id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { config.patternId = id }
        } label: {
            ZStack {
                KlicColor.background
                ChatPatternImage(patternId: id)
                    .opacity(0.5)
            }
            .frame(width: Self.patternTileSize, height: Self.patternTileSize)
            .clipShape(RoundedRectangle(cornerRadius: Self.patternTileRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.patternTileRadius)
                    .strokeBorder(KlicColor.textPrimary.opacity(0.14), lineWidth: 1)
                    .opacity(selected ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.patternTileRadius - 1.5)
                    .inset(by: 1.5)
                    .strokeBorder(KlicColor.primary, lineWidth: 2.5)
                    .opacity(selected ? 1 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(KlicColor.onPrimary)
                        .frame(width: 18, height: 18)
                        .background(KlicColor.primary, in: Circle())
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Gradient

    private var gradientCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background gradient")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    gradientSwatch(nil, label: String(localized: "None"))
                    ForEach(ChatGradientPreset.all) { preset in
                        gradientSwatch(preset, label: preset.label)
                    }
                }
                .padding(.vertical, 2)
            }

            if config.gradientId != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gradient intensity")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textPrimary)
                        Spacer()
                        Text(verbatim: "\(Int((config.gradientIntensity * 100).rounded()))%")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                            .monospacedDigit()
                    }
                    Slider(value: $config.gradientIntensity, in: ChatThemeStore.gradientIntensityRange)
                        .tint(KlicColor.primary)
                }
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func gradientSwatch(_ preset: ChatGradientPreset?, label: String) -> some View {
        let selected = config.gradientId == preset?.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { config.gradientId = preset?.id }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let preset {
                        LinearGradient(
                            colors: [preset.top, preset.bottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        KlicColor.background
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(
                        selected ? KlicColor.primary : KlicColor.surfaceRaised,
                        lineWidth: selected ? 2.5 : 1
                    )
                )
                .overlay {
                    if preset == nil {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                Text(label)
                    .font(KlicFont.caption(11))
                    .foregroundStyle(selected ? KlicColor.textPrimary : KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Bubble color

    private var bubbleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My bubble color")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ChatBubblePalette.all) { palette in
                        bubbleSwatch(palette)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func bubbleSwatch(_ palette: ChatBubblePalette) -> some View {
        let selected = config.bubblePaletteId == palette.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { config.bubblePaletteId = palette.id }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(palette.color)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(KlicColor.onPrimary)
                        }
                    }
                    .overlay(
                        Circle().strokeBorder(
                            selected ? KlicColor.textPrimary.opacity(0.35) : Color.clear,
                            lineWidth: 2
                        )
                    )
                Text(palette.label)
                    .font(KlicFont.caption(11))
                    .foregroundStyle(selected ? KlicColor.textPrimary : KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }
}
