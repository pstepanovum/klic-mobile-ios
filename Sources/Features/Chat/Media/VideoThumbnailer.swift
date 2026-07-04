import SwiftUI
import AVFoundation

/// First-frame thumbnails for VIDEO attachments (§14.2), cached through the existing
/// image cache under a stable per-attachment key. Sent videos are seeded from the
/// local file at send time (instant); received videos generate from the cached local
/// file when present, otherwise straight from the remote asset (AVAssetImageGenerator
/// range-requests just the header + first keyframe — no full download).
enum VideoThumbnailer {
    static func cacheKey(_ attachmentId: String) -> String { "videothumb:\(attachmentId)" }

    /// The cached thumbnail, or nil (no generation attempted).
    static func cached(attachmentId: String) async -> UIImage? {
        await RemoteImageStore.shared.renderedImage(forKey: cacheKey(attachmentId))
    }

    /// Store a locally-generated first frame (send path, §14.2).
    static func store(_ image: UIImage, attachmentId: String) async {
        let scaled = downscale(image)
        await RemoteImageStore.shared.storeRendered(scaled, forKey: cacheKey(attachmentId))
    }

    /// Cached-or-generated thumbnail for a video attachment. Concurrent callers for
    /// the same attachment coalesce on the image store's disk entry (generation is
    /// cheap enough that a rare duplicate race is harmless).
    static func thumbnail(for attachment: Attachment) async -> UIImage? {
        let key = cacheKey(attachment.id)
        if let cached = await RemoteImageStore.shared.renderedImage(forKey: key) {
            return cached
        }
        // Prefer the already-downloaded file; fall back to the presigned remote URL.
        let source = await AttachmentFileStore.shared.cachedURL(for: attachment) ?? URL(string: attachment.url)
        guard let source else { return nil }
        guard let image = await generate(from: source) else { return nil }
        let scaled = downscale(image)
        await RemoteImageStore.shared.storeRendered(scaled, forKey: key)
        return scaled
    }

    private static func generate(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        // A small tolerance lets the generator use the nearest keyframe instead of
        // decoding from the start — much cheaper over the network.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.03, preferredTimescale: 600))
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    /// Keep cached thumbs lightweight (they render at bubble/tile sizes).
    private static func downscale(_ image: UIImage, maxSide: CGFloat = 720) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(px.width, px.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: max(px.width * scale, 1), height: max(px.height * scale, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// A video tile's visual: real first-frame thumbnail once available, dark placeholder
/// until then, with a centered play glyph (§14.2). Reused by chat bubbles / bento
/// tiles, the media browser grid and the viewer's thumbnail strip.
struct VideoThumbnailView: View {
    let attachment: Attachment
    /// Play-glyph size; small tiles pass a smaller one.
    var glyphSize: CGFloat = 40
    var showsGlyph: Bool = true

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                GeometryReader { geo in
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                Color.black.opacity(0.85)
            }
            if showsGlyph {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: glyphSize))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.35), radius: 5)
            }
        }
        .task(id: attachment.id) {
            if thumbnail == nil {
                thumbnail = await VideoThumbnailer.thumbnail(for: attachment)
            }
        }
    }
}
