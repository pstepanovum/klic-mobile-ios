import SwiftUI
import LinkPresentation

// Rich URL preview card for chat messages (website / YouTube / Spotify / etc.),
// built on Apple's LinkPresentation framework — the same one Messages uses.

@MainActor
final class LinkMetadataCache {
    static let shared = LinkMetadataCache()

    private var cache: [String: LPLinkMetadata] = [:]
    private var inFlight: [String: Task<LPLinkMetadata, Error>] = [:]

    func metadata(for url: URL) async throws -> LPLinkMetadata {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return try await running.value }

        // LPMetadataProvider instances are single-use — a fresh one is required per fetch.
        let task = Task<LPLinkMetadata, Error> {
            try await LPMetadataProvider().startFetchingMetadata(for: url)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let result = try await task.value
        cache[key] = result
        return result
    }
}

struct LinkPreviewCard: View {
    let url: URL
    @Environment(\.openURL) private var openURL
    @State private var metadata: LPLinkMetadata?
    @State private var failed = false
    @State private var activeEmbed: VideoEmbed?

    private var videoEmbed: VideoEmbed? { resolveVideoEmbed(for: url) }

    var body: some View {
        Group {
            if let metadata {
                LinkMetadataUIView(metadata: metadata)
            } else if failed {
                chip(icon: "link", label: url.host ?? url.absoluteString)
            } else {
                chip(icon: nil, label: url.host ?? url.absoluteString)
            }
        }
        .background(KlicColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if let embed = videoEmbed {
                activeEmbed = embed
            } else {
                openURL(url)
            }
        }
        .sheet(isPresented: Binding(
            get: { activeEmbed != nil },
            set: { if !$0 { activeEmbed = nil } }
        )) {
            if let activeEmbed {
                VideoEmbedSheet(embed: activeEmbed, originalURL: url)
            }
        }
        .task(id: url) {
            do {
                metadata = try await LinkMetadataCache.shared.metadata(for: url)
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private func chip(icon: String?, label: String) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(KlicColor.textMuted)
            } else {
                ProgressView().tint(KlicColor.textMuted)
            }
            Text(label)
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkMetadataUIView: UIViewRepresentable {
    let metadata: LPLinkMetadata

    func makeUIView(context: Context) -> LPLinkView {
        LPLinkView(metadata: metadata)
    }

    func updateUIView(_ uiView: LPLinkView, context: Context) {
        uiView.metadata = metadata
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        let width = proposal.width ?? 260
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
