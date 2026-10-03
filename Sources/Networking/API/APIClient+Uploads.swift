import Foundation

extension APIClient {
    // MARK: Attachments / media

    /// Step 1: ask the server for a presigned PUT URL for an attachment.
    func requestUpload(conversationId: String, kind: String, contentType: String, byteSize: Int) async throws -> UploadTicket {
        try await post("/uploads", body: [
            "conversationId": conversationId, "kind": kind, "contentType": contentType, "byteSize": byteSize,
        ])
    }

    /// Step 2: PUT the bytes straight to object storage. No auth header; the
    /// Content-Type MUST equal what `requestUpload` was given or the URL's signature fails.
    func uploadData(_ data: Data, to uploadUrl: String, contentType: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await uploadSession.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: data.count, received: 0
        )
    }

    /// Step 2 with byte-level progress (§9.1): same contract as `uploadData`, plus a
    /// 0…1 callback driven by URLSession's didSendBodyData task delegate. The callback
    /// fires on a URLSession queue — callers hop to the main actor themselves.
    func uploadData(
        _ data: Data, to uploadUrl: String, contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (_, resp) = try await uploadSession.upload(for: req, from: data, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: data.count, received: 0
        )
    }

    /// Step 2, streamed from disk (§13.15): PUT a FILE's bytes without ever loading
    /// them into memory — URLSession streams uploadTask(fromFile:) chunk by chunk.
    /// Same progress contract as the Data variant.
    func uploadFile(
        _ fileURL: URL, to uploadUrl: String, contentType: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let url = URL(string: uploadUrl) else { throw APIError.noData }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (_, resp) = try await uploadSession.upload(for: req, fromFile: fileURL, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(message: String(localized: "Upload failed"), status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        DataUsageTracker.shared.record(
            type: DataUsageTracker.mediaType(forContentType: contentType),
            sent: size, received: 0
        )
    }

    /// Step 3: send the message referencing the uploaded object key(s).
    func sendMessage(conversationId: String, body: String?, attachments: [AttachmentDraft], replyToId: String? = nil) async throws -> Message {
        var payload: [String: Any] = [:]
        if let body, !body.isEmpty { payload["body"] = body }
        if let replyToId { payload["replyToId"] = replyToId }
        payload["attachments"] = attachments.map { a -> [String: Any] in
            var d: [String: Any] = ["key": a.key, "kind": a.kind, "contentType": a.contentType, "byteSize": a.byteSize]
            if let w = a.width { d["width"] = w }
            if let h = a.height { d["height"] = h }
            if let ms = a.durationMs { d["durationMs"] = ms }
            if let wf = a.waveform { d["waveform"] = wf.base64EncodedString() }
            if let n = a.fileName { d["fileName"] = n }
            return d
        }
        return try await post("/conversations/\(conversationId)/messages", body: payload)
    }

    /// Re-presign a download URL when an old attachment's link has expired.
    func refreshAttachmentURL(id: String) async throws -> String {
        struct R: Decodable { let url: String }
        let r: R = try await get("/attachments/\(id)/url")
        return r.url
    }
}

/// Task delegate that surfaces upload progress as sent-bytes fractions (§9.1).
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
