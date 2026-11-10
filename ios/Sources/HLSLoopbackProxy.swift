// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Network

enum HLSPlaylist {
    static func rewrite(_ text: String, base: URL, localize: (URL) throws -> URL) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard clean.hasPrefix("#EXTM3U") else { throw CloudError.message("HLS 播放列表无效。") }
        let uri = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return try clean.components(separatedBy: .newlines).map { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return "" }
            func rewritten(_ raw: String) throws -> String {
                guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
                      let secure = MediaNames.secureURL(resolved.absoluteString), secure.user == nil, secure.password == nil else {
                    throw CloudError.message("HLS 包含不受支持的资源地址。")
                }
                return try localize(secure).absoluteString
            }
            if !value.hasPrefix("#") { return try rewritten(value) }
            if value.hasPrefix("#EXT-X-KEY") || value.hasPrefix("#EXT-X-SESSION-KEY") {
                guard !value.contains("METHOD=SAMPLE-AES"), !value.contains("skd:"),
                      !value.contains("KEYFORMAT=") || value.contains("KEYFORMAT=\"identity\"") else {
                    throw CloudError.message("此 HLS 需要受保护的授权播放流程，当前不支持。")
                }
            }
            var result = value
            let matches = uri.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: value), let target = Range(match.range(at: 1), in: result) else { continue }
                result.replaceSubrange(target, with: try rewritten(String(value[range])))
            }
            return result
        }.joined(separator: "\n") + "\n"
    }
}

private final class HLSRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        var safe = request
        for key in ["Cookie", "Authorization", "Proxy-Authorization"] { safe.setValue(nil, forHTTPHeaderField: key) }
        completionHandler(safe)
    }
}

/// AVPlayer receives standard local HTTP HLS. Upstream resources remain HTTPS,
/// every resource uses the same safe media headers, and reads are back-pressured.
actor HLSLoopbackProxy {
    private let initial: URL
    private let headers: [String: String]
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let listener: NWListener
    private let session: URLSession
    private var port: UInt16?
    private var starting: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var closed = false

    init(url: URL, headers: [String: String], configuration: URLSessionConfiguration? = nil) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              !headers.keys.contains(where: { ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased()) }) else {
            throw CloudError.message("HLS 播放不接受非 HTTPS 地址或账号凭证。")
        }
        initial = url
        self.headers = headers.filter { ["referer", "user-agent", "accept"].contains($0.key.lowercased()) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: HLSRedirectPolicy(), delegateQueue: nil)
    }
    func start() async throws -> URL {
        guard !closed else { throw CloudError.message("HLS 播放已关闭。") }
        if port != nil { return try localURL(initial) }
        guard starting == nil else { throw CloudError.message("HLS 播放连接正在启动。") }
        return try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { await self.serve(connection) }
            }
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener.port?.rawValue else { return }
            port = value
            if let starting { self.starting = nil; starting.resume(with: Result { try localURL(initial) }) }
        case .failed, .cancelled:
            if let starting { self.starting = nil; starting.resume(throwing: CloudError.message("无法启动本机 HLS 播放连接。")) }
        default: break
        }
    }
    func stop() {
        closed = true
        listener.cancel(); session.invalidateAndCancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let starting { self.starting = nil; starting.resume(throwing: CancellationError()) }
    }
    private func localURL(_ target: URL) throws -> URL {
        guard let port else { throw CloudError.message("播放连接尚未启动。") }
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = "127.0.0.1"; parts.port = Int(port)
        let ext = target.pathExtension.lowercased()
        parts.path = "/" + token + "/resource" + (ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil ? "." + ext : "")
        let encoded = Data(target.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        parts.queryItems = [URLQueryItem(name: "u", value: encoded)]
        guard let url = parts.url else { throw CloudError.message("播放资源地址无效。") }
        return url
    }
    private func serve(_ connection: NWConnection) async {
        guard !closed, connections.count < 32 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        defer { connection.cancel(); connections.removeValue(forKey: id) }
        var sentHeaders = false
        let headerDeadline = Task {
            do { try await Task.sleep(for: .seconds(10)); connection.cancel() } catch { }
        }
        defer { headerDeadline.cancel() }
        do {
            var input = Data()
            while input.range(of: Data("\r\n\r\n".utf8)) == nil {
                let (data, complete) = try await Self.receive(connection)
                input.append(data)
                guard input.count <= 16_384, !complete || !input.isEmpty else { throw CloudError.message("播放请求无效。") }
                if complete && input.range(of: Data("\r\n\r\n".utf8)) == nil { throw CloudError.message("播放请求不完整。") }
            }
            headerDeadline.cancel()
            guard let text = String(data: input, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else { throw CloudError.message("播放请求无效。") }
            let fields = first.split(separator: " ")
            guard fields.count == 3, fields[0] == "GET", fields[1].hasPrefix("/"), !fields[1].hasPrefix("//"),
                  let parts = URLComponents(string: "http://localhost" + String(fields[1])), parts.path.hasPrefix("/" + token + "/"),
                  let value = parts.queryItems?.first(where: { $0.name == "u" })?.value else {
                try await Self.send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
                return
            }
            var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let decoded = Data(base64Encoded: base64), let raw = String(data: decoded, encoding: .utf8),
                  let target = URL(string: raw), target.scheme == "https", target.user == nil, target.password == nil else { throw CloudError.message("播放资源无效。") }
            var request = URLRequest(url: target)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if target.pathExtension.lowercased() != "m3u8", let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
                let range = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard range.range(of: "^bytes=[0-9]+-[0-9]*$", options: .regularExpression) != nil else { throw CloudError.message("播放范围无效。") }
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else { throw CloudError.message("视频服务器拒绝播放请求。") }
            let mime = http.mimeType?.lowercased() ?? "application/octet-stream"
            let playlist = target.pathExtension.lowercased() == "m3u8" || mime.contains("mpegurl")
            if playlist {
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 2 * 1024 * 1024 else { throw CloudError.message("播放列表过大。") }
                    data.append(byte)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw CloudError.message("播放列表编码无效。") }
                let rewritten = try HLSPlaylist.rewrite(text, base: http.url ?? target) { try localURL($0) }
                let output = Data(rewritten.utf8)
                try await Self.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(output.count)\r\nConnection: close\r\n\r\n".utf8), to: connection)
                sentHeaders = true
                try await Self.send(output, to: connection)
            } else {
                guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("\r"), !mime.contains("\n") else { throw CloudError.message("视频地址返回了验证页面。") }
                var head = "HTTP/1.1 \(http.statusCode) OK\r\nContent-Type: \(mime)\r\nConnection: close\r\n"
                if http.expectedContentLength >= 0 { head += "Content-Length: \(http.expectedContentLength)\r\n" }
                if http.statusCode == 206 {
                    guard let range = http.value(forHTTPHeaderField: "Content-Range"), MovieContentRange.parse(range) != nil else { throw CloudError.message("服务器区间响应无效。") }
                    head += "Content-Range: \(range)\r\n"
                }
                try await Self.send(Data((head + "\r\n").utf8), to: connection)
                sentHeaders = true
                var buffer = Data(); buffer.reserveCapacity(65_536)
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 65_536 { try await Self.send(buffer, to: connection); buffer.removeAll(keepingCapacity: true) }
                }
                if !buffer.isEmpty { try await Self.send(buffer, to: connection) }
            }
            try await Self.finish(connection)
        } catch {
            if !sentHeaders { try? await Self.send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection) }
        }
    }
    nonisolated private static func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }
    nonisolated private static func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    nonisolated private static func finish(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
