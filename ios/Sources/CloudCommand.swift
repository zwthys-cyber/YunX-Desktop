// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Sends only the explicitly confirmed command. Never receives account cookies.
final class CloudCommandClient: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        self.session = NetworkProxy.session(configuration: config, delegate: CloudCommandRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    static func candidate(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf16.count <= 120 && !value.lowercased().contains("http:") && !value.lowercased().contains("https:") && value.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }
    }
    static func xunleiKeyword(_ text: String) -> String? {
        let decorations = CharacterSet(charactersIn: "「」『』【】《》〈〉“”‘’\"'`()（）[]{}<>.,，。;；:：!！?？、|").union(.whitespacesAndNewlines)
        let value = text.trimmingCharacters(in: decorations)
        guard !value.isEmpty, value.utf16.count <= 64, value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains), candidate(value) else { return nil }
        return value
    }
    func resolve(_ text: String, passcode: String = "") async throws -> CloudShare {
        try Task.checkCancellation()
        guard Self.candidate(text) else { throw CloudError.message("请输入不超过 120 字的中文口令。") }
        if let keyword = Self.xunleiKeyword(text) {
            var url = URLComponents(string: "https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump")!
            url.queryItems = ["noredirect": "1", "t": "20", "wd": keyword, "tn": "15007414_5_dg", "src": "lm", "ls": "sm3016480", "lm_extend": "ctype:31"].map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!)
            request.setValue("Mozilla/5.0 Chrome/108.0.5359.215 Safari/537.36 TBC/1.3.3.999 Thunder/12.4.4.3740", forHTTPHeaderField: "User-Agent")
            request.setValue("https://sl-m-ssl.xunlei.com", forHTTPHeaderField: "Origin")
            request.setValue("https://sl-m-ssl.xunlei.com/", forHTTPHeaderField: "Referer")
            if let object = try? await json(request), let ext = object["ext"] as? [String: Any], ext["kouling_type"] as? String == "share_page",
               let location = object["location"] as? String, let share = try? CloudShare.parse(location, override: passcode), share.provider == .xunlei {
                return share
            }
            try Task.checkCancellation()
        }
        var request = URLRequest(url: URL(string: "https://starsea-api.qwq.pics/api/resolve")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Public application key from the desktop source, not an account credential.
        request.setValue("8bfbe163c670ae500aca5f3b2f060ecc8463e1eb1691ba8d", forHTTPHeaderField: "X-API-Key")
        var payload = ["clipboard": text.trimmingCharacters(in: .whitespacesAndNewlines), "platform": "auto", "step": "parse"]
        if !passcode.isEmpty { payload["passcode"] = passcode }
        request.httpBody = try JSONEncoder().encode(payload)
        let object = try await json(request)
        guard object["success"] as? Bool == true, let data = object["data"] as? [String: Any],
              let platform = (data["platform"] as? String)?.lowercased(), ["qk", "uc"].contains(platform),
              let id = data["pwdId"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw CloudError.message("口令无效、已过期或服务暂不可用。请尝试原始分享链接。")
        }
        return try CloudShare.parse("https://\(platform == "uc" ? "drive.uc.cn" : "pan.quark.cn")/s/\(id)", override: passcode)
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("口令服务暂不可用，请稍后重试。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 262144 else { throw CloudError.message("口令服务响应过大。") }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("口令服务返回无效结果。") }
        return object
    }
}

private final class CloudCommandRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
