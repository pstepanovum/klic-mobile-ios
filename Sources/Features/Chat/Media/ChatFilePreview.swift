import SwiftUI
import QuickLook

/// Downloads FILE attachments into the app's caches directory (keyed by attachment id)
/// so they can be viewed in-app. Publishes per-attachment progress for the bubble UI.
/// The presigned media URL is only ever fetched here — it is never opened externally.
@MainActor
final class AttachmentFileStore: ObservableObject {
    static let shared = AttachmentFileStore()

    /// attachmentId → 0…1 while a download is in flight.
    @Published private(set) var progress: [String: Double] = [:]

    private var inFlight: [String: Task<URL, Error>] = [:]

    nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether an attachment's bytes are already cached locally.
    func isCached(_ attachment: Attachment) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: attachment).path)
    }

    /// The cached file's URL when present (nil when not yet downloaded).
    func cachedURL(for attachment: Attachment) -> URL? {
        let url = localURL(for: attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// On-disk size of one cached attachment (0 when absent) — drives "Manage storage".
    nonisolated static func cachedBytes(attachmentId: String) -> Int64 {
        directorySize(directory.appendingPathComponent(attachmentId, isDirectory: true))
    }

    nonisolated static func removeCached(attachmentId: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(attachmentId, isDirectory: true))
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Local cache location for an attachment. The original file name is kept as the
    /// path's last component (inside a per-attachment folder) so Quick Look and the
    /// share sheet show the real name and pick the right renderer by extension.
    private func localURL(for attachment: Attachment) -> URL {
        let name = (attachment.fileName?.isEmpty == false ? attachment.fileName! : "file")
            .replacingOccurrences(of: "/", with: "_")
        return Self.directory
            .appendingPathComponent(attachment.id, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Returns the cached file immediately when present, otherwise downloads it,
    /// reporting progress along the way. Concurrent calls for the same attachment
    /// share one download.
    func download(_ attachment: Attachment) async throws -> URL {
        let destination = localURL(for: attachment)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if let task = inFlight[attachment.id] {
            return try await task.value
        }
        guard let remote = URL(string: attachment.url) else { throw URLError(.badURL) }
        let expectedBytes = attachment.byteSize
        let attachmentId = attachment.id
        progress[attachmentId] = 0
        let task = Task<URL, Error> {
            // Streams to a temp file via a URLSession download task (off the main actor)
            // and moves it into place — no per-byte loop, no whole file held in memory.
            let received = try await Self.downloadFile(
                from: remote, to: destination, expectedBytes: expectedBytes
            ) { value in
                Task { @MainActor in AttachmentFileStore.shared.reportProgress(value, for: attachmentId) }
            }
            DataUsageTracker.shared.record(
                type: DataUsageTracker.mediaType(forAttachmentKind: attachment.kind),
                sent: 0, received: Int(clamping: received)
            )
            return destination
        }
        inFlight[attachment.id] = task
        defer {
            inFlight[attachment.id] = nil
            progress[attachment.id] = nil
        }
        do {
            return try await task.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Progress hop from the download's KVO callback. Ignored once the download is no
    /// longer in flight, so a late hop can't resurrect a cleared progress entry (which
    /// would leave the bubble's ring spinning and its button disabled).
    fileprivate func reportProgress(_ value: Double, for attachmentId: String) {
        guard inFlight[attachmentId] != nil else { return }
        progress[attachmentId] = value
    }

    /// Downloads `remote` to a temporary file with a `URLSessionDownloadTask`, then
    /// moves it to `destination`. Reports 0…1 progress in ≥2% steps (falling back to
    /// `expectedBytes` when the server sends no Content-Length). Cancelling the calling
    /// Swift task cancels the URLSession task. Returns the number of bytes written.
    nonisolated private static func downloadFile(
        from remote: URL,
        to destination: URL,
        expectedBytes: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let state = FileDownloadState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                let task = URLSession.shared.downloadTask(with: remote) { tempURL, response, error in
                    state.finish()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let tempURL,
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    // The temp file is deleted when this handler returns — move it now.
                    do {
                        let fm = FileManager.default
                        try fm.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        if fm.fileExists(atPath: destination.path) {
                            try fm.removeItem(at: destination)
                        }
                        try fm.moveItem(at: tempURL, to: destination)
                        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
                            .int64Value ?? 0
                        continuation.resume(returning: size)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let progress = task.progress
                let observation = progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
                    let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : Int64(expectedBytes)
                    guard total > 0 else { return }
                    let fraction = min(Double(progress.completedUnitCount) / Double(total), 1)
                    if state.shouldReport(fraction) { onProgress(fraction) }
                }
                state.start(task, observation: observation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Lock-protected bookkeeping shared between a file download's URLSession callbacks,
/// its progress KVO and the Swift task's cancellation handler (all on different threads).
private final class FileDownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false
    private var lastReported = 0.0

    /// Resumes the task; if cancellation already happened, cancels it right away.
    func start(_ task: URLSessionDownloadTask, observation: NSKeyValueObservation) {
        lock.lock()
        self.task = task
        self.observation = observation
        let alreadyCancelled = cancelled
        lock.unlock()
        task.resume()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// Stops progress observation and drops the task reference (completion).
    func finish() {
        lock.lock()
        let observation = self.observation
        self.observation = nil
        task = nil
        lock.unlock()
        observation?.invalidate()
    }

    /// True when `fraction` advanced ≥2% since the last report (or reached 100%).
    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction - lastReported >= 0.02 || (fraction >= 1 && lastReported < 1) else { return false }
        lastReported = fraction
        return true
    }
}

/// Quick Look preview of a single LOCAL file (pdf, audio, docs, …) — covers everything
/// §7.3 needs without ever exposing the remote URL.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in context.coordinator.dismiss() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onDismiss = { dismiss() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: { dismiss() })
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var onDismiss: () -> Void

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func dismiss() { onDismiss() }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
