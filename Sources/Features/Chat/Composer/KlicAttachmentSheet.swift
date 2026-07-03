import SwiftUI
import Photos
import PhotosUI
import VisionKit

/// The composer's + sheet (§10.11): ONE Klic bottom sheet with Gallery | Files tabs.
/// Gallery = a live PHAsset grid (newest first, multi-select, album dropdown,
/// limited-library aware) with a "Select from Gallery" system-picker fallback.
/// Files = "Select from Files" + "Scan Document" (VisionKit → multi-page PDF).
struct KlicAttachmentSheet: View {
    /// Multi-selected grid assets → the caller stages them into the pre-send flow.
    let onSendAssets: ([PHAsset]) -> Void
    let onOpenSystemPicker: () -> Void
    let onOpenCamera: () -> Void
    let onSelectFiles: () -> Void
    let onScanDocument: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .gallery
    @State private var authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selected: [String] = []       // localIdentifiers, in pick order
    @State private var album: Album = .recents
    @State private var availableAlbums: [Album] = [.recents]
    @State private var showAlbumSheet = false

    private enum Tab: String, CaseIterable, Identifiable {
        case gallery, files
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gallery: return String(localized: "Gallery")
            case .files:   return String(localized: "Files")
            }
        }
    }

    private enum Album: String, CaseIterable, Identifiable {
        case recents, favorites, videos, selfies
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recents:   return String(localized: "Recents")
            case .favorites: return String(localized: "Favorites")
            case .videos:    return String(localized: "Videos")
            case .selfies:   return String(localized: "Selfies")
            }
        }
        var subtype: PHAssetCollectionSubtype {
            switch self {
            case .recents:   return .smartAlbumUserLibrary
            case .favorites: return .smartAlbumFavorites
            case .videos:    return .smartAlbumVideos
            case .selfies:   return .smartAlbumSelfPortraits
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented capsule: Gallery | Files.
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = item }
                    } label: {
                        Text(item.label)
                            .font(KlicFont.headline(14))
                            .foregroundStyle(tab == item ? KlicColor.onPrimary : KlicColor.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(tab == item ? KlicColor.primary : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(KlicColor.surfaceRaised, in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            switch tab {
            case .gallery: galleryTab
            case .files: filesTab
            }
        }
        .background(KlicColor.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadLibrary() }
        .klicSelectionSheet(
            isPresented: $showAlbumSheet,
            title: String(localized: "Album"),
            options: availableAlbums.map { KlicSheetOption(id: $0.rawValue, label: $0.label) },
            selectedId: album.rawValue
        ) { option in
            guard let picked = Album(rawValue: option.id) else { return }
            album = picked
            Task { await fetchAssets() }
        }
    }

    // MARK: Gallery tab

    @ViewBuilder private var galleryTab: some View {
        VStack(spacing: 0) {
            // Album dropdown pill "Recents ▾" (§10.11).
            HStack {
                Button { showAlbumSheet = true } label: {
                    HStack(spacing: 5) {
                        Text(album.label)
                            .font(KlicFont.headline(14))
                            .foregroundStyle(KlicColor.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(KlicColor.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                if !selected.isEmpty {
                    Button {
                        let picked = selectedAssets()
                        dismiss()
                        onSendAssets(picked)
                    } label: {
                        Text("Send (\(selected.count))")
                            .font(KlicFont.headline(14))
                            .foregroundStyle(KlicColor.onPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(KlicColor.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if authStatus == .denied || authStatus == .restricted {
                deniedState
            } else {
                ScrollView {
                    // Limited library: surface the "manage" row (§10.11).
                    if authStatus == .limited {
                        Button {
                            presentLimitedLibraryPicker()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Klic can only access some photos. Manage…")
                                    .font(KlicFont.caption(12))
                            }
                            .foregroundStyle(KlicColor.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            AssetGridCell(
                                asset: asset,
                                selectionIndex: selected.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
                            ) {
                                toggle(asset)
                            }
                        }
                    }
                    .padding(.horizontal, 2)

                    // Fallback: the full system picker (current flow).
                    capsuleButton(String(localized: "Select from Gallery"), systemImage: "photo.on.rectangle") {
                        dismiss()
                        onOpenSystemPicker()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var deniedState: some View {
        VStack(spacing: 12) {
            Text("Klic doesn't have access to your photos.")
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
                .multilineTextAlignment(.center)
            capsuleButton(String(localized: "Allow in Settings"), systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            capsuleButton(String(localized: "Select from Gallery"), systemImage: "photo.on.rectangle") {
                dismiss()
                onOpenSystemPicker()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Files tab

    private var filesTab: some View {
        VStack(spacing: 12) {
            capsuleButton(String(localized: "Select from Files"), systemImage: "folder") {
                dismiss()
                onSelectFiles()
            }
            // Document camera → multi-page PDF → normal file-send flow (§10.11).
            if VNDocumentCameraViewController.isSupported {
                capsuleButton(String(localized: "Scan Document"), systemImage: "doc.viewfinder") {
                    dismiss()
                    onScanDocument()
                }
            }
            capsuleButton(String(localized: "Camera"), systemImage: "camera") {
                dismiss()
                onOpenCamera()
            }
            Spacer()
        }
        .padding(20)
    }

    private func capsuleButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(KlicColor.primary)
                Text(title)
                    .font(KlicFont.headline(15))
                    .foregroundStyle(KlicColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .background(KlicColor.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Library plumbing

    private func loadLibrary() async {
        if authStatus == .notDetermined {
            authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authStatus == .authorized || authStatus == .limited else { return }
        await resolveAlbums()
        await fetchAssets()
    }

    /// Hide smart albums the platform can't provide (empty/unavailable).
    private func resolveAlbums() async {
        var available: [Album] = []
        for candidate in Album.allCases {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: candidate.subtype, options: nil
            )
            guard let collection = collections.firstObject else { continue }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if candidate == .recents || count > 0 {
                available.append(candidate)
            }
        }
        availableAlbums = available.isEmpty ? [.recents] : available
    }

    private func fetchAssets() async {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 400

        var fetched: [PHAsset] = []
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: album.subtype, options: nil
        )
        if let collection = collections.firstObject {
            let result = PHAsset.fetchAssets(in: collection, options: options)
            result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        } else {
            let result = PHAsset.fetchAssets(with: options)
            result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        }
        assets = fetched
        selected.removeAll { id in !fetched.contains(where: { $0.localIdentifier == id }) }
    }

    private func toggle(_ asset: PHAsset) {
        if let idx = selected.firstIndex(of: asset.localIdentifier) {
            selected.remove(at: idx)
        } else if selected.count < 10 {
            selected.append(asset.localIdentifier)
        }
    }

    private func selectedAssets() -> [PHAsset] {
        selected.compactMap { id in assets.first(where: { $0.localIdentifier == id }) }
    }

    private func presentLimitedLibraryPicker() {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        if let top {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
        }
    }
}

// MARK: - Grid cell

private struct AssetGridCell: View {
    let asset: PHAsset
    let selectionIndex: Int?
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    private static let manager = PHCachingImageManager()

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                KlicColor.surfaceRaised
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if asset.mediaType == .video {
                Text(Self.durationText(asset.duration))
                    .font(KlicFont.caption(10).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
            } else if asset.mediaSubtypes.contains(.photoLive) {
                Image(systemName: "livephoto")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(selectionIndex != nil ? KlicColor.primary : .black.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                if let selectionIndex {
                    Text("\(selectionIndex)")
                        .font(KlicFont.caption(11).weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            Self.manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                if let image { thumbnail = image }
            }
        }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Document scanner (§10.11)

/// VisionKit document camera; scanned pages are rendered into one multi-page PDF and
/// handed back as a temp file URL for the normal file-send flow.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onPDF: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.dismiss()
            guard !pages.isEmpty else { return }
            let name = "Scan \(Self.dateStamp()).pdf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let bounds = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))   // US Letter @72dpi
            do {
                try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
                    for page in pages {
                        context.beginPage()
                        let fitted = Self.aspectFit(page.size, in: bounds.size)
                        page.draw(in: fitted)
                    }
                }
                parent.onPDF(url)
            } catch {
                // Rendering failed — nothing staged.
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.dismiss()
        }

        private static func aspectFit(_ size: CGSize, in container: CGSize) -> CGRect {
            guard size.width > 0, size.height > 0 else {
                return CGRect(origin: .zero, size: container)
            }
            let scale = min(container.width / size.width, container.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(
                x: (container.width - fitted.width) / 2,
                y: (container.height - fitted.height) / 2,
                width: fitted.width, height: fitted.height
            )
        }

        private static func dateStamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            return formatter.string(from: Date())
        }
    }
}
