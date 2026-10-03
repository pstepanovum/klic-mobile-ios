import Foundation

extension APIClient {
    nonisolated static func mobileDiagnostic(event: String, callId: String? = nil, detail: String? = nil) {
        guard let url = URL(string: baseURL.absoluteString + "/diagnostics/mobile-event") else { return }
        var body: [String: Any] = ["source": "ios", "event": event]
        if let callId { body["callId"] = callId }
        if let detail { body["detail"] = String(detail.prefix(500)) }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }
}
