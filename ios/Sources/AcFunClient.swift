// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor
final class AcFunClient {
    let session: URLSession
    init(session: URLSession) { self.session = session }
    func resolve(_ link: MediaLink, cookie: String) async throws -> MediaResult {
        var parts = URLComponents(string: "https://www.acfun.cn/v/ac" + link.id)!
        parts.queryItems = [URLQueryItem(name: "quickViewId", value: "videoInfo_new"), URLQueryItem(name: "ajaxpipe", value: "1")]
        var request = URLRequest(url: parts.url!)
        request.setValue(MediaClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.acfun.cn/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.message("AcFun 作品页未返回成功响应，请检查作品和验证要求。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 3 * 1024 * 1024 else { throw CloudError.message("AcFun 作品页超过当前上限。") }
            data.append(byte)
        }
        guard let original = String(data: data, encoding: .utf8) else { throw CloudError.message("AcFun 页面编码无法识别。") }
        let html: String
        // Some ajaxpipe responses wrap the HTML in a JSON string or an html property.
        if let wrapped = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            html = (wrapped as? String) ?? (wrapped as? [String: Any])?["html"] as? String ?? original
        } else { html = original }
        let info = try InlineJSON.object(html, marker: "window.videoInfo")
        guard let current = info["currentVideoInfo"] as? [String: Any] else { throw CloudError.message("AcFun 缺少当前视频信息。") }
        let play: [String: Any]
        if let object = current["ksPlayJson"] as? [String: Any] { play = object }
        else if let raw = current["ksPlayJson"] as? String, let encoded = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] { play = object }
        else { throw CloudError.message("AcFun 播放信息格式无法识别。") }
        guard let representations = (play["adaptationSet"] as? [[String: Any]])?.first?["representation"] as? [[String: Any]], !representations.isEmpty, representations.count <= 50 else {
            throw CloudError.message("AcFun 未返回视频流，或作品类型不受支持。")
        }
        let title = info["title"] as? String ?? "AcFun 视频"
        let base = MediaNames.filename(title, fallback: "acfun_" + link.id)
        var assets: [MediaAsset] = []
        var seen = Set<URL>()
        for (index, representation) in representations.enumerated() {
            guard let raw = representation["url"] as? String, let url = MediaNames.secureURL(raw), url.pathExtension.lowercased() == "m3u8" else {
                throw CloudError.message("AcFun 返回了不受支持的视频流地址，未创建伪装的 MP4 下载。")
            }
            guard seen.insert(url).inserted else { continue }
            let label = representation["qualityLabel"] as? String ?? "平台视频流 \(index + 1)"
            assets.append(MediaAsset(id: "hls-\(index)", url: url, previewURL: nil, filename: base + "_\(index + 1).m3u8", label: label + " · HLS", size: nil, kind: .video,
                                     headers: ["User-Agent": MediaClient.userAgent, "Referer": "https://www.acfun.cn/"], isHLS: true))
        }
        return MediaResult(title: title, author: (info["user"] as? [String: Any])?["name"] as? String ?? "", source: link.url, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }
}
