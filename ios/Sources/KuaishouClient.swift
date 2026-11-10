// SPDX-License-Identifier: AGPL-3.0-only
// Port of desktop KuaishouParser.kt; JSON is parsed, never evaluated as JavaScript.
import Foundation

enum InlineJSON {
    static func object(_ html: String, marker: String) throws -> [String: Any] {
        guard html.utf8.count <= 3 * 1024 * 1024 else { throw CloudError.message("作品页面超过当前大小上限。") }
        let pattern = NSRegularExpression.escapedPattern(for: marker) + #"\s*=\s*"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { throw CloudError.message("平台未返回作品数据，可能需要在官网完成验证。") }
        let remainder = html[range.upperBound...]
        guard remainder.first == "{" else { throw CloudError.message("作品数据不是预期 JSON 对象。") }
        var depth = 0
        var quoted = false
        var escaped = false
        for index in remainder.indices {
            let character = remainder[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" || character == "[" { depth += 1 }
            else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 {
                    let raw = Data(remainder[...index].utf8)
                    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw CloudError.message("平台作品数据格式无法识别。") }
                    return object
                }
            }
        }
        throw CloudError.message("平台作品数据不完整。")
    }
}

@MainActor
final class KuaishouClient {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    nonisolated static func allowed(_ host: String) -> Bool {
        ["kuaishou.com", "www.kuaishou.com", "v.kuaishou.com", "m.kuaishou.com", "chenzhongtech.com", "v.m.chenzhongtech.com"].contains(host.lowercased())
    }
    let session: URLSession
    init(session: URLSession) { self.session = session }
    func resolve(_ link: MediaLink, cookie: String) async throws -> MediaResult {
        guard let secure = MediaNames.secureURL(link.url.absoluteString) else { throw CloudError.message("快手作品地址无效。") }
        var url = secure
        var seen = Set<URL>()
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard url.scheme?.lowercased() == "https", Self.allowed(url.host ?? ""), seen.insert(url).inserted else {
                throw CloudError.message("快手跳转到了不支持的地址或发生循环。")
            }
            if url.path.contains("/fw/long-video/") {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                parts.path = parts.path.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")
                guard let normalized = parts.url else { throw CloudError.message("快手作品地址无效。") }
                url = normalized
            }
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://v.kuaishou.com/", forHTTPHeaderField: "Referer")
            let host = url.host?.lowercased() ?? ""
            if !cookie.isEmpty, host == "kuaishou.com" || host.hasSuffix(".kuaishou.com") { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw CloudError.message("快手页面响应无效。") }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                url = next; continue
            }
            guard http.statusCode == 200 else { throw CloudError.message("快手作品页被拒绝，请稍后或在官网检查验证要求。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 3 * 1024 * 1024 else { throw CloudError.message("快手作品页面过大。") }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8) else { throw CloudError.message("快手页面编码无法识别。") }
            return try build(InlineJSON.object(html, marker: "window.INIT_STATE"), link: link)
        }
        throw CloudError.message("快手页面跳转次数过多。")
    }
    private func build(_ root: [String: Any], link: MediaLink) throws -> MediaResult {
        let candidates = root.keys.sorted().compactMap { (root[$0] as? [String: Any])?["photo"] as? [String: Any] }
        let matching = candidates.first { ($0["id"] as? String ?? $0["photoId"] as? String) == link.id }
        guard let photo = matching ?? (candidates.count == 1 ? candidates.first : nil) else { throw CloudError.message("快手未返回唯一的目标作品数据。") }
        let title = photo["caption"] as? String ?? "快手作品"
        let base = MediaNames.filename(title, fallback: "kuaishou_" + link.id)
        let headers = ["User-Agent": Self.userAgent, "Referer": "https://v.kuaishou.com/"]
        var assets: [MediaAsset] = []
        if let urls = photo["mainMvUrls"] as? [[String: Any]], let url = urls.compactMap({ ($0["url"] as? String).flatMap(MediaNames.secureURL) }).first {
            assets.append(MediaAsset(id: "video", url: url, previewURL: nil, filename: base + ".mp4", label: "平台单文件视频", size: nil, kind: .video, headers: headers))
        }
        if let atlas = (photo["ext_params"] as? [String: Any])?["atlas"] as? [String: Any], let routes = atlas["list"] as? [String], !routes.isEmpty {
            guard routes.count <= 1000, let cdn = (atlas["cdnList"] as? [[String: Any]])?.first?["cdn"] as? String,
                  let origin = MediaNames.secureURL(cdn.contains("://") ? cdn : "https://" + cdn), origin.user == nil, origin.password == nil else {
                throw CloudError.message("快手图集 CDN 信息不完整或图集过大。")
            }
            for (index, route) in routes.enumerated() {
                guard !route.isEmpty, let url = MediaNames.secureURL(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + route.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
                    throw CloudError.message("快手图集缺少图片，未返回不完整图集。")
                }
                let ext = ["jpg", "jpeg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
                assets.append(MediaAsset(id: "image-\(index)", url: url, previewURL: nil, filename: base + "_\(index + 1)." + ext, label: "平台图集 \(index + 1)/\(routes.count)", size: nil, kind: .image, headers: headers))
            }
        }
        guard !assets.isEmpty else { throw CloudError.message("快手没有返回可下载媒体。") }
        return MediaResult(title: title, author: (photo["userName"] as? String ?? "").replacingOccurrences(of: "\u{3164}", with: "").trimmingCharacters(in: .whitespacesAndNewlines), source: link.url, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }
}
