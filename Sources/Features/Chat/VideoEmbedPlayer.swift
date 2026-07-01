import SwiftUI
import WebKit

// Keeps YouTube / TikTok / Instagram Reels playback inside the app by loading
// each platform's official embeddable player page in a WKWebView, instead of
// handing the user off to Safari or another app.

struct VideoEmbed {
    let platform: String
    let embedURL: URL
    let aspectRatio: CGFloat
}

func resolveVideoEmbed(for url: URL) -> VideoEmbed? {
    guard let host = url.host?.lowercased() else { return nil }

    if host.contains("youtube.com") || host.contains("youtu.be") {
        guard let id = youTubeVideoID(from: url) else { return nil }
        // youtube-nocookie.com is Google's own embed domain for third-party apps —
        // it also behaves more reliably inside a WKWebView than youtube.com/embed.
        guard let embedURL = URL(string: "https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&rel=0&modestbranding=1") else { return nil }
        return VideoEmbed(platform: "YouTube", embedURL: embedURL, aspectRatio: 16.0 / 9.0)
    }

    if host.contains("tiktok.com") {
        guard let id = tikTokVideoID(from: url) else { return nil }
        guard let embedURL = URL(string: "https://www.tiktok.com/embed/v2/\(id)") else { return nil }
        return VideoEmbed(platform: "TikTok", embedURL: embedURL, aspectRatio: 9.0 / 16.0)
    }

    if host.contains("instagram.com") {
        guard let (kind, code) = instagramReelCode(from: url) else { return nil }
        guard let embedURL = URL(string: "https://www.instagram.com/\(kind)/\(code)/embed") else { return nil }
        return VideoEmbed(platform: "Instagram", embedURL: embedURL, aspectRatio: 9.0 / 16.0)
    }

    return nil
}

private func youTubeVideoID(from url: URL) -> String? {
    let path = url.pathComponents.filter { $0 != "/" }
    if url.host?.lowercased().contains("youtu.be") == true { return path.first }
    if path.first == "shorts", path.count > 1 { return path[1] }
    if path.first == "embed", path.count > 1 { return path[1] }
    if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
        return v
    }
    return nil
}

private func tikTokVideoID(from url: URL) -> String? {
    let path = url.pathComponents.filter { $0 != "/" }
    guard let videoIdx = path.firstIndex(of: "video"), path.count > videoIdx + 1 else { return nil }
    return path[videoIdx + 1]
}

private func instagramReelCode(from url: URL) -> (String, String)? {
    let path = url.pathComponents.filter { $0 != "/" }
    guard let kind = path.first, ["reel", "p", "tv"].contains(kind), path.count > 1 else { return nil }
    return (kind, path[1])
}

private struct VideoEmbedWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var failed: Bool

    // Embed players (esp. YouTube's) serve a broken/limited page to WKWebView's
    // default user agent since it doesn't identify as a real mobile browser.
    private static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.mobileSafariUserAgent
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading, failed: $failed) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var failed: Bool
        init(isLoading: Binding<Bool>, failed: Binding<Bool>) {
            _isLoading = isLoading
            _failed = failed
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            failed = true
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            failed = true
        }
    }
}

struct VideoEmbedSheet: View {
    let embed: VideoEmbed
    let originalURL: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(embed.platform)
                    .font(KlicFont.headline(16))
                    .foregroundStyle(KlicColor.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .padding()

            ZStack {
                if failed {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("Couldn't load this video")
                            .font(KlicFont.body(14))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    VideoEmbedWebView(url: embed.embedURL, isLoading: $isLoading, failed: $failed)
                    if isLoading {
                        ProgressView().tint(.white)
                    }
                }
            }
            .aspectRatio(embed.aspectRatio, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Spacer()

            Button {
                dismiss()
                openURL(originalURL)
            } label: {
                Text("Open in \(embed.platform)")
                    .font(KlicFont.body(14))
                    .foregroundStyle(KlicColor.primary)
            }
            .padding(.bottom, 24)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
