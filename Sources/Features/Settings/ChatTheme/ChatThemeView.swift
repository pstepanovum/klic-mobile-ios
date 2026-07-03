import SwiftUI
import Inject

/// Settings → Chat theme (§12.3): live mini-chat preview, pattern grid, pattern
/// opacity, gradient presets + intensity, own-bubble color, and Reset.
struct ChatThemeView: View {
    @ObserveInjection var inject
    @ObservedObject private var theme = ChatThemeStore.shared

    private let patternColumns = [GridItem(.adaptive(minimum: 64), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewCard
                patternCard
                gradientCard
                bubbleCard

                PillButton(
                    title: String(localized: "Reset theme"),
                    fill: KlicColor.surface,
                    textColor: KlicColor.danger
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { theme.reset() }
                }
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Chat theme")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }

    // MARK: Live preview

    private var previewCard: some View {
        ZStack {
            ChatThemeBackground()
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
                .background(mine ? theme.bubbleColor : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 40) }
        }
    }

    // MARK: Pattern

    private var patternCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background pattern")
                .font(KlicFont.headline(17))
                .foregroundStyle(KlicColor.textPrimary)

            LazyVGrid(columns: patternColumns, spacing: 10) {
                ForEach(1...10, id: \.self) { id in
                    patternSwatch(id)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pattern opacity")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text(verbatim: "\(Int((theme.patternOpacity * 100).rounded()))%")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .monospacedDigit()
                }
                Slider(value: $theme.patternOpacity, in: ChatThemeStore.patternOpacityRange)
                    .tint(KlicColor.primary)
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func patternSwatch(_ id: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { theme.patternId = id }
        } label: {
            ZStack {
                KlicColor.background
                ChatPatternImage(patternId: id)
                    .opacity(0.5)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        theme.patternId == id ? KlicColor.primary : KlicColor.surfaceRaised,
                        lineWidth: theme.patternId == id ? 2 : 1
                    )
            )
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

            if theme.gradientId != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gradient intensity")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textPrimary)
                        Spacer()
                        Text(verbatim: "\(Int((theme.gradientIntensity * 100).rounded()))%")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                            .monospacedDigit()
                    }
                    Slider(value: $theme.gradientIntensity, in: ChatThemeStore.gradientIntensityRange)
                        .tint(KlicColor.primary)
                }
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func gradientSwatch(_ preset: ChatGradientPreset?, label: String) -> some View {
        let selected = theme.gradientId == preset?.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { theme.gradientId = preset?.id }
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
        let selected = theme.bubblePaletteId == palette.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { theme.bubblePaletteId = palette.id }
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
