import SwiftUI
import PencilKit

/// Pre-send media editor (§10.9): caption at the bottom, tool row on top —
/// Drawing (PencilKit + colors + undo), Text overlay (draggable/scalable),
/// Crop/rotate (aspect presets + 90°), Quality (HD/Standard override per send).
/// The output is a flattened image (drawing + text baked in via UIGraphicsImageRenderer).
/// Videos get caption + quality only this pass.
struct MediaEditorView: View {
    let draft: PendingMediaDraft
    @Binding var caption: String
    let onSave: (PendingMediaDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Tool: String, Identifiable {
        case draw, text, crop
        var id: String { rawValue }
    }

    private struct TextOverlayItem: Identifiable {
        let id = UUID()
        var text: String
        var color: Color
        var offset: CGSize = .zero
        var lastOffset: CGSize = .zero
        var scale: CGFloat = 1
        var lastScale: CGFloat = 1
    }

    @State private var baseImage: UIImage?
    @State private var activeTool: Tool?
    @State private var canvasView = PKCanvasView()
    @State private var drawColor: Color = .white
    @State private var textOverlays: [TextOverlayItem] = []
    @State private var newTextInput = ""
    @State private var showTextInput = false
    @State private var quality: UploadQuality = .current
    @State private var showQualitySheet = false
    @State private var showAspectSheet = false
    @State private var saving = false

    private var isImage: Bool { draft.kind == "IMAGE" }

    private static let drawPalette: [Color] = [.white, .black, KlicColor.primary, .yellow, .blue, .green]

    var body: some View {
        VStack(spacing: 0) {
            topBar

            GeometryReader { proxy in
                stage(in: proxy.size)
            }

            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            if baseImage == nil {
                baseImage = draft.previewImage ?? UIImage(data: draft.data)
            }
        }
        .klicSelectionSheet(
            isPresented: $showQualitySheet,
            title: String(localized: "Upload quality"),
            options: [
                KlicSheetOption(id: UploadQuality.hd.rawValue, label: String(localized: "HD"),
                                subtitle: String(localized: "Best quality, larger upload")),
                KlicSheetOption(id: UploadQuality.standard.rawValue, label: String(localized: "Standard"),
                                subtitle: String(localized: "Smaller and faster")),
            ],
            selectedId: quality.rawValue
        ) { option in
            if let picked = UploadQuality(rawValue: option.id) { quality = picked }
        }
        .klicSelectionSheet(
            isPresented: $showAspectSheet,
            title: String(localized: "Crop"),
            options: [
                KlicSheetOption(id: "free", label: String(localized: "Original")),
                KlicSheetOption(id: "1:1", label: String(localized: "Square (1:1)")),
                KlicSheetOption(id: "4:3", label: "4:3"),
                KlicSheetOption(id: "16:9", label: "16:9"),
                KlicSheetOption(id: "rotate", label: String(localized: "Rotate 90°")),
            ]
        ) { option in
            applyCropOption(option.id)
        }
        .alert(String(localized: "Add text"), isPresented: $showTextInput) {
            TextField(String(localized: "Your text"), text: $newTextInput)
            Button(String(localized: "Cancel"), role: .cancel) { newTextInput = "" }
            Button(String(localized: "Add")) {
                let trimmed = newTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    textOverlays.append(TextOverlayItem(text: trimmed, color: drawColor))
                }
                newTextInput = ""
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }

            Spacer()

            if isImage {
                toolButton("pencil.tip", tool: .draw)
                toolButton("textformat", tool: .text)
                Button { showAspectSheet = true } label: {
                    toolIcon("crop.rotate", active: false)
                }
                .buttonStyle(.plain)
            }
            Button { showQualitySheet = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dial.high")
                        .font(.system(size: 15, weight: .semibold))
                    Text(quality == .hd ? "HD" : "SD")
                        .font(KlicFont.caption(11).weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)

            if activeTool == .draw {
                Button { canvasView.undoManager?.undo() } label: {
                    toolIcon("arrow.uturn.backward", active: false)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func toolButton(_ icon: String, tool: Tool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if tool == .text {
                    activeTool = nil
                    showTextInput = true
                } else {
                    activeTool = activeTool == tool ? nil : tool
                }
            }
        } label: {
            toolIcon(icon, active: activeTool == tool)
        }
        .buttonStyle(.plain)
    }

    private func toolIcon(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(active ? .black : .white)
            .frame(width: 38, height: 38)
            .background(active ? Color.white : Color.white.opacity(0.14), in: Circle())
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(in size: CGSize) -> some View {
        if let baseImage {
            let fitted = Self.fittedSize(image: baseImage.size, in: size)
            ZStack {
                Image(uiImage: baseImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fitted.width, height: fitted.height)

                if isImage {
                    DrawingCanvas(
                        canvasView: canvasView,
                        color: UIColor(drawColor),
                        active: activeTool == .draw
                    )
                    .frame(width: fitted.width, height: fitted.height)

                    ForEach($textOverlays) { $item in
                        Text(item.text)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(item.color)
                            .scaleEffect(item.scale)
                            .offset(item.offset)
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        item.offset = CGSize(
                                            width: item.lastOffset.width + value.translation.width,
                                            height: item.lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in item.lastOffset = item.offset }
                            )
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        item.scale = max(0.4, min(item.lastScale * value, 6))
                                    }
                                    .onEnded { _ in item.lastScale = item.scale }
                            )
                            .onTapGesture(count: 2) {
                                textOverlays.removeAll { $0.id == item.id }
                            }
                    }

                    if draft.isLivePhoto {
                        HStack(spacing: 4) {
                            Image(systemName: "livephoto")
                                .font(.system(size: 10, weight: .semibold))
                            Text("LIVE")
                                .font(KlicFont.caption(10).weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                        .padding(8)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        } else {
            Color.black
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if activeTool == .draw {
                HStack(spacing: 14) {
                    ForEach(Array(Self.drawPalette.enumerated()), id: \.offset) { _, color in
                        Button {
                            drawColor = color
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().stroke(.white, lineWidth: drawColor == color ? 3 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }

            HStack(spacing: 10) {
                TextField(String(localized: "Add a caption"), text: $caption, axis: .vertical)
                    .lineLimit(1...3)
                    .font(KlicFont.body())
                    .foregroundStyle(.white)
                    .tint(KlicColor.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.12), in: Capsule())

                Button {
                    Task { await save() }
                } label: {
                    Image(systemName: saving ? "hourglass" : "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(KlicColor.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(KlicColor.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: Crop / rotate

    private func applyCropOption(_ id: String) {
        guard let image = baseImage else { return }
        switch id {
        case "rotate":
            baseImage = Self.rotate90(image)
        case "1:1":
            baseImage = Self.centerCrop(image, aspect: 1)
        case "4:3":
            baseImage = Self.centerCrop(image, aspect: 4.0 / 3.0)
        case "16:9":
            baseImage = Self.centerCrop(image, aspect: 16.0 / 9.0)
        default:
            break
        }
        // Geometry changed — existing strokes/text no longer line up; reset them.
        canvasView.drawing = PKDrawing()
        textOverlays.removeAll()
    }

    static func rotate90(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(
                x: -image.size.width / 2, y: -image.size.height / 2,
                width: image.size.width, height: image.size.height
            ))
        }
    }

    static func centerCrop(_ image: UIImage, aspect: CGFloat) -> UIImage {
        let current = image.size.width / image.size.height
        var cropSize = image.size
        if current > aspect {
            cropSize.width = image.size.height * aspect
        } else {
            cropSize.height = image.size.width / aspect
        }
        let origin = CGPoint(
            x: (image.size.width - cropSize.width) / 2,
            y: (image.size.height - cropSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: cropSize, format: format).image { _ in
            image.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }

    static func fittedSize(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    // MARK: Save (flatten)

    private func save() async {
        saving = true
        defer { saving = false }

        if !isImage {
            // Video: caption is bound to the composer; only the quality override applies.
            UploadQuality.current = quality
            dismiss()
            return
        }

        guard let image = baseImage else { return }
        let flattened = flatten(base: image)
        guard let (jpeg, w, h) = Media.encodeImage(
            flattened,
            maxDimension: quality.imageMaxDimension,
            quality: quality.imageJpegQuality
        ) else { return }

        var updated = PendingMediaDraft(
            kind: "IMAGE",
            contentType: "image/jpeg",
            data: jpeg,
            previewImage: flattened,
            width: w,
            height: h,
            fileName: draft.fileName
        )
        updated.isLivePhoto = false   // edits flatten motion away
        onSave(updated)
        dismiss()
    }

    /// Bake drawing + text overlays into the base image at full resolution.
    private func flatten(base: UIImage) -> UIImage {
        let hasDrawing = !canvasView.drawing.strokes.isEmpty
        guard hasDrawing || !textOverlays.isEmpty else { return base }

        // The canvas + overlays are laid out over the FITTED image rect; map their
        // coordinates into image pixels through the fitted→pixel scale factor.
        let fittedWidth = canvasView.bounds.width > 0 ? canvasView.bounds.width : base.size.width
        let pixelScale = base.size.width / fittedWidth

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))

            if hasDrawing {
                let drawingImage = canvasView.drawing.image(
                    from: CGRect(origin: .zero, size: canvasView.bounds.size),
                    scale: pixelScale
                )
                drawingImage.draw(in: CGRect(origin: .zero, size: base.size))
            }

            for item in textOverlays {
                let fontSize = 28 * item.scale * pixelScale
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: UIColor(item.color),
                ]
                let attributed = NSAttributedString(string: item.text, attributes: attributes)
                let textSize = attributed.size()
                let center = CGPoint(
                    x: base.size.width / 2 + item.offset.width * pixelScale,
                    y: base.size.height / 2 + item.offset.height * pixelScale
                )
                attributed.draw(at: CGPoint(
                    x: center.x - textSize.width / 2,
                    y: center.y - textSize.height / 2
                ))
            }
        }
    }
}

/// Transparent PencilKit canvas layered over the staged image.
private struct DrawingCanvas: UIViewRepresentable {
    let canvasView: PKCanvasView
    let color: UIColor
    let active: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: color, width: 6)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = PKInkingTool(.pen, color: color, width: 6)
        uiView.isUserInteractionEnabled = active
    }
}
