// SPDX-License-Identifier: AGPL-3.0-only
// Port of desktop WeiboParser.kt: status, video fid, retweets and image originals.
import Foundation

@MainActor
final class WeiboClient {
    let session: URLSession
    init(session: URLSession) { self.session = session }
    func resolve(_ link: MediaLink, cookie: String) async throws -> MediaResult {
        if link.kind == "fid" { return try await video(link, cookie: cookie) }
        let identifier = link.kind == "tv" ? Self.midToID(link.id) : link.id
        guard !identifier.isEmpty else { throw CloudError.message("微博作品标识无效。") }
        var parts = URLComponents(string: "https://m.weibo.cn/statuses/show")!
        parts.queryItems = [URLQueryItem(name: "id", value: identifier), URLQueryItem(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))]
        var request = URLRequest(url: parts.url!)
        request.setValue("https://m.weibo.cn/detail/" + identifier, forHTTPHeaderField: "Referer")
        request.setValue("https://m.weibo.cn", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("1", forHTTPHeaderField: "mweibo-pwa")
        let root = try await fetch(request, cookie: cookie)
        guard let data = root["data"] as? [String: Any] else { throw CloudError.message("微博作品不存在、不可见或需要重新登录。") }
        return try build(data, link: link, allowRetweet: true)
    }
    private func video(_ link: MediaLink, cookie: String) async throws -> MediaResult {
        var parts = URLComponents(string: "https://h5.video.weibo.com/api/component")!
        parts.queryItems = [URLQueryItem(name: "page", value: "/show/" + link.id)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("https://h5.video.weibo.com/show/" + link.id, forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let payload = try JSONSerialization.data(withJSONObject: ["Component_Play_Playinfo": ["oid": link.id]])
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: String(decoding: payload, as: UTF8.self))]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let root = try await fetch(request, cookie: cookie)
        guard let data = (root["data"] as? [String: Any])?["Component_Play_Playinfo"] as? [String: Any] else {
            throw CloudError.message("微博未返回视频数据，作品可能不可见。")
        }
        let title = data["title"] as? String ?? "微博视频"
        let base = MediaNames.filename(title, fallback: "weibo_" + link.id)
        let urls = data["urls"] as? [String: String] ?? [:]
        var assets: [MediaAsset] = []
        var seen = Set<URL>()
        for key in urls.keys.sorted() {
            if let raw = urls[key], let url = MediaNames.secureURL(raw), seen.insert(url).inserted {
                assets.append(asset(url, id: "video-" + key, filename: base + "_" + MediaNames.filename(key, fallback: "video") + ".mp4", label: key, kind: .video))
            }
        }
        if assets.isEmpty, let raw = data["stream_url"] as? String, let url = MediaNames.secureURL(raw) {
            assets = [asset(url, id: "video", filename: base + ".mp4", label: "平台单文件视频", kind: .video)]
        }
        guard !assets.isEmpty else { throw CloudError.message("微博没有返回可下载的视频。") }
        let author = ((data["reward"] as? [String: Any])?["user"] as? [String: Any])?["name"] as? String ?? ""
        return MediaResult(title: title, author: author, source: link.url, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }
    private func build(_ data: [String: Any], link: MediaLink, allowRetweet: Bool) throws -> MediaResult {
        let page = data["page_info"] as? [String: Any] ?? [:]
        let text = (data["text"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let title = page["title"] as? String ?? (text.isEmpty ? "微博作品" : text)
        let base = MediaNames.filename(title, fallback: "weibo_" + link.id)
        var assets: [MediaAsset] = []
        let urls = page["urls"] as? [String: String] ?? [:]
        for key in ["mp4_720p_mp4", "mp4_hd_mp4", "mp4_ld_mp4"] {
            if let raw = urls[key], let url = MediaNames.secureURL(raw) {
                assets.append(asset(url, id: "video", filename: base + ".mp4", label: key, kind: .video)); break
            }
        }
        let pictures = data["pics"] as? [[String: Any]] ?? []
        guard pictures.count <= 1000 else { throw CloudError.message("微博图集超过当前上限。") }
        for (index, picture) in pictures.enumerated() {
            guard let raw = (picture["large"] as? [String: Any])?["url"] as? String,
                  let url = MediaNames.secureURL(raw) else { throw CloudError.message("微博图集缺少原图地址，未返回不完整图集。") }
            let ext = ["jpg", "jpeg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
            assets.append(asset(url, id: "image-\(index)", filename: base + "_\(index + 1)." + ext, label: "原图 \(index + 1)/\(pictures.count)", kind: .image))
            if let rawMotion = picture["videoSrc"] as? String, !rawMotion.isEmpty {
                guard let motion = MediaNames.secureURL(rawMotion) else { throw CloudError.message("微博动态照片的视频地址无效。") }
                assets[assets.count - 1].livePhotoVideoURL = motion
                assets.append(asset(motion, id: "motion-\(index)", filename: base + "_\(index + 1)_motion.mov", label: "动态照片视频部分（未合成）", kind: .video))
            }
        }
        if assets.isEmpty, allowRetweet, let retweeted = data["retweeted_status"] as? [String: Any] { return try build(retweeted, link: link, allowRetweet: false) }
        guard !assets.isEmpty else { throw CloudError.message("微博未返回可下载媒体，作品可能不可见或需要登录。") }
        return MediaResult(title: title, author: (data["user"] as? [String: Any])?["screen_name"] as? String ?? "", source: link.url, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }
    private func asset(_ url: URL, id: String, filename: String, label: String, kind: MediaAsset.Kind) -> MediaAsset {
        MediaAsset(id: id, url: url, previewURL: nil, filename: filename, label: label, size: nil, kind: kind,
                   headers: ["User-Agent": MediaClient.userAgent, "Referer": "https://weibo.com/"])
    }
    private func fetch(_ original: URLRequest, cookie: String) async throws -> [String: Any] {
        guard let url = original.url, ["m.weibo.cn", "h5.video.weibo.com"].contains(url.host?.lowercased() ?? ""), url.scheme == "https" else {
            throw CloudError.message("微博 API 地址无效。")
        }
        var request = original
        request.setValue(MediaClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true else {
            throw CloudError.message("微博返回登录/验证页面或拒绝请求，请在官网检查后重试。")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw CloudError.message("微博接口响应超过当前上限。") }
            data.append(byte)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("微博数据格式无法识别。") }
        return root
    }
    static func midToID(_ mid: String) -> String {
        guard !mid.isEmpty, mid.count <= 24, mid.allSatisfy(\.isNumber) else { return "" }
        let characters = Array(mid)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var end = characters.count
        var output: [String] = []
        while end > 0 {
            let start = max(0, end - 7)
            guard var number = Int(String(characters[start..<end])) else { return "" }
            var encoded = ""
            repeat { encoded = String(alphabet[number % 62]) + encoded; number /= 62 } while number > 0
            if start > 0 { encoded = String(repeating: "0", count: max(0, 4 - encoded.count)) + encoded }
            output.insert(encoded, at: 0); end = start
        }
        return output.joined()
    }
}
