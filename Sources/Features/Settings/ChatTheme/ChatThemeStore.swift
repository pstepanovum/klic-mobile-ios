import SwiftUI

/// Local-only chat theme (CALLS.md §12.3): background pattern + opacity, an optional
/// subtle two-stop gradient, and the own-bubble accent color. Applies to ALL
/// conversations; persisted in UserDefaults — no server involvement.
@MainActor
final class ChatThemeStore: ObservableObject {
    static let shared = ChatThemeStore()

    // Contract defaults (§12.3): pattern 1, ~4% opacity, flat (no gradient), Klic red.
    static let defaultPatternId = 1
    static let defaultPatternOpacity = 0.04
    static let patternOpacityRange = 0.02...0.10
    static let defaultGradientIntensity = 0.15
    static let gradientIntensityRange = 0.05...0.30

    @Published var patternId: Int {
        didSet { defaults.set(patternId, forKey: Keys.pattern) }
    }
    /// Deliberately subtle — clamped so the pattern never overpowers content.
    @Published var patternOpacity: Double {
        didSet { defaults.set(patternOpacity, forKey: Keys.patternOpacity) }
    }
    /// nil = flat background (the default).
    @Published var gradientId: String? {
        didSet { defaults.set(gradientId ?? "", forKey: Keys.gradient) }
    }
    @Published var gradientIntensity: Double {
        didSet { defaults.set(gradientIntensity, forKey: Keys.gradientIntensity) }
    }
    @Published var bubblePaletteId: String {
        didSet { defaults.set(bubblePaletteId, forKey: Keys.bubble) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pattern = "klic.chatTheme.pattern"
        static let patternOpacity = "klic.chatTheme.patternOpacity"
        static let gradient = "klic.chatTheme.gradient"
        static let gradientIntensity = "klic.chatTheme.gradientIntensity"
        static let bubble = "klic.chatTheme.bubble"
    }

    init() {
        let storedPattern = defaults.integer(forKey: Keys.pattern)
        patternId = (1...10).contains(storedPattern) ? storedPattern : Self.defaultPatternId

        let storedOpacity = defaults.double(forKey: Keys.patternOpacity)
        patternOpacity = storedOpacity == 0
            ? Self.defaultPatternOpacity
            : storedOpacity.clamped(to: Self.patternOpacityRange)

        let storedGradient = defaults.string(forKey: Keys.gradient) ?? ""
        gradientId = ChatGradientPreset.all.contains(where: { $0.id == storedGradient }) ? storedGradient : nil

        let storedIntensity = defaults.double(forKey: Keys.gradientIntensity)
        gradientIntensity = storedIntensity == 0
            ? Self.defaultGradientIntensity
            : storedIntensity.clamped(to: Self.gradientIntensityRange)

        let storedBubble = defaults.string(forKey: Keys.bubble) ?? ""
        bubblePaletteId = ChatBubblePalette.all.contains(where: { $0.id == storedBubble })
            ? storedBubble
            : ChatBubblePalette.defaultId
    }

    var gradientPreset: ChatGradientPreset? {
        gradientId.flatMap { id in ChatGradientPreset.all.first { $0.id == id } }
    }

    /// The own-bubble accent (also used for the send button).
    var bubbleColor: Color {
        (ChatBubblePalette.all.first { $0.id == bubblePaletteId } ?? ChatBubblePalette.all[0]).color
    }

    func reset() {
        patternId = Self.defaultPatternId
        patternOpacity = Self.defaultPatternOpacity
        gradientId = nil
        gradientIntensity = Self.defaultGradientIntensity
        bubblePaletteId = ChatBubblePalette.defaultId
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Curated presets

/// Two-stop background gradient with per-scheme stops, drawn UNDER the pattern at a
/// user-controlled (but always subtle) intensity.
struct ChatGradientPreset: Identifiable {
    let id: String
    let label: String
    let lightTop: UInt32
    let lightBottom: UInt32
    let darkTop: UInt32
    let darkBottom: UInt32

    var top: Color { Color.adaptive(dark: darkTop, light: lightTop) }
    var bottom: Color { Color.adaptive(dark: darkBottom, light: lightBottom) }

    static let all: [ChatGradientPreset] = [
        ChatGradientPreset(
            id: "dawn", label: String(localized: "Dawn"),
            lightTop: 0xFF8A65, lightBottom: 0xF06292,
            darkTop: 0xB3541E, darkBottom: 0x8E2A52
        ),
        ChatGradientPreset(
            id: "ocean", label: String(localized: "Ocean"),
            lightTop: 0x42A5F5, lightBottom: 0x26C6DA,
            darkTop: 0x0D47A1, darkBottom: 0x006064
        ),
        ChatGradientPreset(
            id: "meadow", label: String(localized: "Meadow"),
            lightTop: 0x66BB6A, lightBottom: 0x26A69A,
            darkTop: 0x1B5E20, darkBottom: 0x00483F
        ),
        ChatGradientPreset(
            id: "dusk", label: String(localized: "Dusk"),
            lightTop: 0x7E57C2, lightBottom: 0x5C6BC0,
            darkTop: 0x3A1F71, darkBottom: 0x1A2472
        ),
        ChatGradientPreset(
            id: "ember", label: String(localized: "Ember"),
            lightTop: 0xEF5350, lightBottom: 0xFFA726,
            darkTop: 0x7F1D1D, darkBottom: 0x7C4A03
        ),
    ]
}

/// Curated own-bubble colors — every pick keeps white text readable (§12.3).
struct ChatBubblePalette: Identifiable {
    let id: String
    let label: String
    let hex: UInt32

    var color: Color { Color(hex: hex) }

    static let defaultId = "klic"

    static let all: [ChatBubblePalette] = [
        ChatBubblePalette(id: "klic", label: String(localized: "Klic Red"), hex: 0xED122B),
        ChatBubblePalette(id: "ocean", label: String(localized: "Ocean"), hex: 0x1565C0),
        ChatBubblePalette(id: "forest", label: String(localized: "Forest"), hex: 0x2E7D32),
        ChatBubblePalette(id: "violet", label: String(localized: "Violet"), hex: 0x6A3DD8),
        ChatBubblePalette(id: "sunset", label: String(localized: "Sunset"), hex: 0xE05A00),
        ChatBubblePalette(id: "graphite", label: String(localized: "Graphite"), hex: 0x455A64),
        ChatBubblePalette(id: "rose", label: String(localized: "Rose"), hex: 0xC2185B),
    ]
}

// MARK: - Background stack

/// The chat background stack (§12.3): background color → gradient layer → pattern layer.
/// Used by every chat screen and by the theme page's live preview.
struct ChatThemeBackground: View {
    @ObservedObject private var theme = ChatThemeStore.shared

    var body: some View {
        ZStack {
            KlicColor.background
            if let preset = theme.gradientPreset {
                LinearGradient(
                    colors: [preset.top, preset.bottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(theme.gradientIntensity)
            }
            ChatPatternImage(patternId: theme.patternId)
                .opacity(theme.patternOpacity)
        }
    }
}

/// One bundled line-art pattern, template-tinted so it adapts to light/dark.
struct ChatPatternImage: View {
    let patternId: Int

    var body: some View {
        Image("ChatPattern\(patternId)")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fill)
            .foregroundStyle(KlicColor.textPrimary)
            .allowsHitTesting(false)
            .clipped()
    }
}
