import SwiftUI
import UIKit

/// §11.5 image-adjust step: before a new profile picture or group cover uploads, the
/// picked image is positioned with pinch-zoom + drag inside a mask — circular for
/// profiles, rounded-square for group covers — and cropped to a square bitmap that
/// then rides the existing upload flow.
struct KlicImageAdjustSheet: View {
    enum MaskShape {
        case circle
        case roundedSquare
    }

    let mask: MaskShape
    let onDone: (UIImage) -> Void
    /// Orientation-normalized source (the gesture math assumes .up).
    private let source: UIImage

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxZoom: CGFloat = 5

    init(image: UIImage, mask: MaskShape, onDone: @escaping (UIImage) -> Void) {
        self.mask = mask
        self.onDone = onDone
        self.source = Self.normalized(image)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 48
            let cropCenter = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                KlicColor.background.ignoresSafeArea()

                imageLayer(side: side, center: cropCenter)

                maskOverlay(side: side, center: cropCenter)

                VStack {
                    Text(mask == .circle ? String(localized: "Adjust your photo") : String(localized: "Adjust the cover"))
                        .font(KlicFont.headline(16))
                        .foregroundStyle(KlicColor.textPrimary)
                        .padding(.top, 26)
                    Text("Pinch to zoom, drag to position")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.top, 2)
                    Spacer()
                    HStack(spacing: 12) {
                        PillButton(title: String(localized: "Cancel"), fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                            dismiss()
                        }
                        PillButton(title: String(localized: "Choose")) {
                            let cropped = renderCrop(side: side)
                            dismiss()
                            onDone(cropped)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .contentShape(Rectangle())
            .gesture(adjustGesture(side: side))
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(KlicColor.background)
    }

    // MARK: Layers

    private func imageLayer(side: CGFloat, center: CGPoint) -> some View {
        let display = displaySize(side: side)
        return Image(uiImage: source)
            .resizable()
            .frame(width: display.width, height: display.height)
            .position(x: center.x + offset.width, y: center.y + offset.height)
    }

    @ViewBuilder
    private func maskOverlay(side: CGFloat, center: CGPoint) -> some View {
        ZStack {
            // Dim everything outside the crop window; the window itself is punched out.
            Rectangle()
                .fill(KlicColor.background.opacity(0.72))
            maskShape(side: side)
                .frame(width: side, height: side)
                .position(center)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .overlay {
            maskStroke(side: side)
                .frame(width: side, height: side)
                .position(center)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func maskShape(side: CGFloat) -> some View {
        switch mask {
        case .circle:        Circle()
        case .roundedSquare: RoundedRectangle(cornerRadius: side * 0.18)
        }
    }

    @ViewBuilder
    private func maskStroke(side: CGFloat) -> some View {
        switch mask {
        case .circle:
            Circle().strokeBorder(KlicColor.textPrimary.opacity(0.35), lineWidth: 1.5)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: side * 0.18)
                .strokeBorder(KlicColor.textPrimary.opacity(0.35), lineWidth: 1.5)
        }
    }

    // MARK: Gestures

    private func adjustGesture(side: CGFloat) -> some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(width: lastOffset.width + value.translation.width,
                           height: lastOffset.height + value.translation.height),
                    side: side
                )
            }
            .onEnded { _ in lastOffset = offset }

        let zoom = MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), maxZoom)
                offset = clampedOffset(offset, side: side)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }

        return drag.simultaneously(with: zoom)
    }

    // MARK: Geometry

    /// Displayed image size: aspect-fill of the crop square, times the user zoom.
    private func displaySize(side: CGFloat) -> CGSize {
        let size = source.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let fill = max(side / size.width, side / size.height) * scale
        return CGSize(width: size.width * fill, height: size.height * fill)
    }

    /// Keep the crop window fully covered by the image.
    private func clampedOffset(_ proposed: CGSize, side: CGFloat) -> CGSize {
        let display = displaySize(side: side)
        let maxX = max((display.width - side) / 2, 0)
        let maxY = max((display.height - side) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    // MARK: Crop

    /// Render the crop-window contents into a square bitmap (≤1024px).
    private func renderCrop(side: CGFloat) -> UIImage {
        let img = source
        let size = img.size
        guard size.width > 0, size.height > 0, side > 0 else { return img }
        let fill = max(side / size.width, side / size.height) * scale

        // Crop-window origin in image points.
        let originX = (size.width * fill / 2 - offset.width - side / 2) / fill
        let originY = (size.height * fill / 2 - offset.height - side / 2) / fill
        let cropSide = side / fill
        let rect = CGRect(x: originX, y: originY, width: cropSide, height: cropSide)
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isEmpty else { return img }

        let output = min(max(rect.width * img.scale, 1), 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format)
            .image { _ in
                let drawScale = output / rect.width
                img.draw(in: CGRect(
                    x: -rect.minX * drawScale,
                    y: -rect.minY * drawScale,
                    width: size.width * drawScale,
                    height: size.height * drawScale
                ))
            }
    }

    /// Redraw so imageOrientation is .up — the geometry above assumes it.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
