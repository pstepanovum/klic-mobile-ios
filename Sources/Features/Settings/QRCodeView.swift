import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

/// Settings → QR Code (§10.7/§13.8): a card with the user's avatar, name and a QR
/// encoding https://klic.pstepanov.dev/u/<username> (generated locally with
/// CoreImage), a Scan tab that parses the /u/ and /add/ URL forms plus the legacy
/// klic.app / raw-@username payloads into the add-friend flow, and a ShareLink
/// exporting the QR image.
struct QRCodeView: View {
    @EnvironmentObject var session: AppSession
    @State private var tab: Tab = .myCode

    private enum Tab: String, CaseIterable, Identifiable {
        case myCode, scan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .myCode: return String(localized: "My Code")
            case .scan:   return String(localized: "Scan")
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Segmented capsule switch.
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { tab = item }
                    } label: {
                        Text(item.label)
                            .font(KlicFont.headline(14))
                            .foregroundStyle(tab == item ? KlicColor.onPrimary : KlicColor.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(tab == item ? KlicColor.primary : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(KlicColor.surface, in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if tab == .myCode {
                myCodeCard
            } else {
                QRScanPane()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: My code

    private var addLink: String {
        FriendLinkRouter.link(forUsername: session.currentUser?.username ?? "")
    }

    private var myCodeCard: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 14) {
                    if let user = session.currentUser {
                        AvatarView(url: user.avatarUrl, name: user.displayName, size: 72)
                        Text(user.displayName)
                            .font(KlicFont.headline(20))
                            .foregroundStyle(KlicColor.textPrimary)
                        CopyableUsername(username: user.username)
                    }

                    if let qr = Self.qrImage(for: addLink) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    }

                    Text("Friends can scan this code to add you on Klic.")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 24))

                if let shareImage = Self.shareableQRImage(for: addLink) {
                    ShareLink(
                        item: Image(uiImage: shareImage),
                        preview: SharePreview(String(localized: "My Klic QR code"), image: Image(uiImage: shareImage))
                    ) {
                        Text("Share My Code")
                            .font(KlicFont.headline())
                            .foregroundStyle(KlicColor.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(KlicColor.primary, in: Capsule())
                    }
                }
            }
            .padding(20)
        }
    }

    /// Raw QR bitmap (module-exact, no interpolation).
    static func qrImage(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// QR on a white card with padding — what the share sheet exports.
    static func shareableQRImage(for string: String) -> UIImage? {
        guard let qr = qrImage(for: string) else { return nil }
        let padding: CGFloat = 48
        let size = CGSize(width: qr.size.width + padding * 2, height: qr.size.height + padding * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            qr.draw(at: CGPoint(x: padding, y: padding))
        }
    }
}

// MARK: - Scan pane

private struct QRScanPane: View {
    @State private var scanned: String?
    @State private var resolvedUsername: String?
    @State private var statusText: String?
    @State private var sending = false
    @State private var cameraDenied = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if cameraDenied {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(KlicColor.textMuted)
                        Text("Allow camera access in iOS Settings to scan QR codes.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                } else {
                    QRScannerView { code in
                        handle(code)
                    } onDenied: {
                        cameraDenied = true
                    }
                }
            }
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 20)

            if let resolvedUsername {
                VStack(spacing: 10) {
                    Text("@\(resolvedUsername)")
                        .font(KlicFont.headline(18))
                        .foregroundStyle(KlicColor.textPrimary)
                    PillButton(title: sending ? String(localized: "Sending…") : String(localized: "Send Friend Request")) {
                        Task { await sendRequest(resolvedUsername) }
                    }
                    .disabled(sending)
                    .padding(.horizontal, 20)
                }
            } else {
                Text("Point the camera at a Klic QR code.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
            }

            if let statusText {
                Text(statusText)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Accepts https://klic.pstepanov.dev/u|add/<username>, the legacy klic.app
    /// links, and raw "@username" payloads (§10.7/§13.8).
    private func handle(_ code: String) {
        guard resolvedUsername == nil || scanned != code else { return }
        scanned = code
        guard let username = FriendLinkRouter.username(fromScannedCode: code) else {
            statusText = String(localized: "That doesn't look like a Klic code.")
            return
        }
        resolvedUsername = username
        statusText = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func sendRequest(_ username: String) async {
        sending = true
        defer { sending = false }
        guard let users = try? await APIClient.shared.findUser(username: username),
              let target = users.first else {
            statusText = String(localized: "No user named \"\(username)\".")
            return
        }
        do {
            _ = try await APIClient.shared.sendFriendRequest(userId: target.id)
            statusText = String(localized: "Request sent to \(target.displayName).")
            resolvedUsername = nil
        } catch let e as APIError {
            statusText = e.userMessage
        } catch {
            statusText = String(localized: "Couldn't send the request.")
        }
    }
}

/// AVFoundation QR scanner surface.
private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onDenied = onDenied
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void = { _ in }
        var onDenied: () -> Void = {}

        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var lastEmitted: (code: String, at: Date)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configure() } else { self.onDenied() }
                }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onDenied()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            // Debounce repeat frames of the same code.
            if let last = lastEmitted, last.code == value, Date().timeIntervalSince(last.at) < 2 { return }
            lastEmitted = (value, Date())
            onCode(value)
        }
    }
}
