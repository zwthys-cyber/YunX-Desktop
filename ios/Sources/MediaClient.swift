// SPDX-License-Identifier: AGPL-3.0-only
// Ported from BilibiliParser.kt and PixivParser.kt; single-file media only.
import Foundation

final class MediaNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class MediaClient {
    nonisolated static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }

    func validate(provider: MediaProvider, cookie: String) async throws -> String {
        guard provider.supportsAccountValidation else { throw CloudError.message("此平台暂不支持账号有效性验证，可使用手动 Cookie 尝试解析。") }
        guard !cookie.isEmpty else { throw CloudError.message("请先完成登录。") }
        if provider == .bilibili {
            let root = try await json("https://api.bilibili.com/x/web-interface/nav", provider: provider, cookie: cookie)
            guard let body = root["data"] as? [String: Any], body["isLogin"] as? Bool == true,
                  let name = body["uname"] as? String, !name.isEmpty else {
                throw CloudError.message("B 站登录状态无效。")
            }
            return name
        }
        let (_, response) = try await fetch(URL(string: "https://www.pixiv.net/dashboard/works")!,
                                             provider: provider, cookie: cookie)
        guard (200..<300).contains(response.statusCode) else {
            throw CloudError.message("Pixiv 尚未完成登录或登录状态已失效。")
        }
        return "Pixiv 已登录"
    }

    func resolve(_ link: MediaLink, cookie: String = "", part: Int? = nil, quality: Int? = nil, preferDASH: Bool = false) async throws -> MediaResult {
        let target: MediaLink
        if link.isShort { target = try await expand(link) } else { target = link }
        switch target.provider {
        case .bilibili: return try await bilibili(target, cookie: cookie, part: part ?? target.part, quality: quality, preferDASH: preferDASH)
        case .pixiv: return try await pixiv(target, cookie: cookie)
        case .weibo: return try await WeiboClient(session: session).resolve(target, cookie: cookie)
        case .kuaishou: return try await KuaishouClient(session: session).resolve(target, cookie: cookie)
        case .acfun: return try await AcFunClient(session: session).resolve(target, cookie: cookie)
        case .douyin, .xhs: throw CloudError.message("此平台需要在作品页完成验证后读取，请使用应用内作品页。")
        }
    }

    private func expand(_ link: MediaLink) async throws -> MediaLink {
        var url = link.url
        for _ in 0..<5 {
            try Task.checkCancellation()
            if let result = MediaLink.parseURL(url), result.provider == .bilibili, !result.isShort { return result }
            guard let host = url.host?.lowercased(),
                  ["b23.tv", "bili2233.cn"].contains(host),
                  let secure = MediaNames.secureURL(url.absoluteString) else {
                throw CloudError.message("短链跳转到了不支持的平台地址。")
            }
            // Never send account cookies to short-link hosts.
            let (_, response) = try await fetch(secure, provider: .bilibili, cookie: "")
            guard (300..<400).contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: secure)?.absoluteURL,
                  next.scheme?.lowercased() == "https" else {
                throw CloudError.message("短链未返回可识别的安全跳转地址。")
            }
            url = next
        }
        throw CloudError.message("短链跳转次数过多，请使用完整作品链接。")
    }

    private func bilibili(_ link: MediaLink, cookie: String, part: Int, quality: Int?, preferDASH: Bool) async throws -> MediaResult {
        let queryKey = link.id.lowercased().hasPrefix("bv") ? "bvid" : "aid"
        let identifier = queryKey == "aid" ? String(link.id.dropFirst(2)) : "BV" + String(link.id.dropFirst(2))
        let view = try await json(apiURL("/x/web-interface/view", query: [queryKey: identifier]),
                                  provider: .bilibili, cookie: cookie)
        guard let data = view["data"] as? [String: Any], let bvid = data["bvid"] as? String,
              bvid.range(of: #"^BV[A-Za-z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw CloudError.message("B 站作品信息缺少标识。")
        }
        var parts: [MediaPart] = []
        for (index, page) in ((data["pages"] as? [[String: Any]]) ?? []).enumerated() {
            if let cid = page["cid"] as? NSNumber {
                parts.append(MediaPart(id: index + 1, title: page["part"] as? String ?? "P\(index + 1)", cid: cid.int64Value))
            }
        }
        if parts.isEmpty, let cid = data["cid"] as? NSNumber {
            parts = [MediaPart(id: 1, title: "P1", cid: cid.int64Value)]
        }
        guard let selected = parts.first(where: { $0.id == part }) else {
            throw CloudError.message("该分 P 不存在，请检查链接中的 p 参数。")
        }
        var fallbackNotice: String?
        if preferDASH && !cookie.isEmpty {
            do { return try await bilibiliDASH(data: data, bvid: bvid, selected: selected, parts: parts, cookie: cookie, quality: quality) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                fallbackNotice = "平台未返回适配的 DASH 音视频分轨，已回退单文件流；画质以实际结果为准。"
            }
        }
        let play = try await json(apiURL("/x/player/playurl", query: [
            "bvid": bvid, "cid": String(selected.cid), "qn": String(quality ?? 80),
            "fnval": "1", "fnver": "0", "fourk": "1", "platform": "html5", "high_quality": "1"
        ]), provider: .bilibili, cookie: cookie)
        guard let playData = play["data"] as? [String: Any],
              let segments = playData["durl"] as? [[String: Any]], !segments.isEmpty else {
            throw CloudError.message("平台未返回单文件视频，可尝试较低画质；高清分轨、番剧和付费内容暂不支持。")
        }
        let title = data["title"] as? String ?? bvid
        let name = MediaNames.filename(title, fallback: bvid) + (parts.count > 1 ? "_P\(part)" : "")
        let actualQuality = (playData["quality"] as? NSNumber)?.intValue ?? 0
        let headers = ["User-Agent": Self.userAgent, "Referer": MediaProvider.bilibili.origin]
        let assets: [MediaAsset] = try segments.enumerated().map { index, segment in
            let candidates = ([segment["url"] as? String].compactMap { $0 } +
                              ((segment["backup_url"] as? [String]) ?? [])).compactMap(MediaNames.secureURL)
            guard let url = candidates.first(where: { !($0.host ?? "").contains("mcdn") }) ?? candidates.first else {
                throw CloudError.message("视频分段缺少可用直链，未创建不完整下载。")
            }
            let suffix = segments.count > 1 ? "_片段\(index + 1)" : ""
            return MediaAsset(id: "\(selected.cid)-\(index)", url: url, previewURL: nil,
                              filename: name + "_" + MediaNames.quality(actualQuality) + suffix + ".mp4",
                              label: MediaNames.quality(actualQuality) + (segments.count > 1 ? " · 片段 \(index + 1)/\(segments.count)" : ""),
                              size: (segment["size"] as? NSNumber)?.int64Value, kind: .video, headers: headers)
        }
        var qualities: [MediaQuality] = []
        let ids = playData["accept_quality"] as? [Int] ?? []
        let descriptions = playData["accept_description"] as? [String] ?? []
        for (index, number) in ids.enumerated() {
            qualities.append(MediaQuality(id: number, title: index < descriptions.count ? descriptions[index] : MediaNames.quality(number)))
        }
        if qualities.isEmpty { qualities = [MediaQuality(id: actualQuality, title: MediaNames.quality(actualQuality))] }
        var seen = Set<Int>()
        qualities = qualities.filter { seen.insert($0.id).inserted }.sorted { $0.id > $1.id }
        var result = MediaResult(title: title, author: (data["owner"] as? [String: Any])?["name"] as? String ?? "",
                           source: URL(string: "https://www.bilibili.com/video/\(bvid)?p=\(part)")!,
                           assets: assets, parts: parts, qualities: qualities, selectedPart: part, actualQuality: actualQuality)
        result.notice = fallbackNotice
        result.concatenateSegments = segments.count > 1
        return result
    }

    private func bilibiliDASH(data: [String: Any], bvid: String, selected: MediaPart, parts: [MediaPart], cookie: String, quality: Int?) async throws -> MediaResult {
        let root = try await json(apiURL("/x/player/playurl", query: ["bvid": bvid, "cid": String(selected.cid), "qn": String(quality ?? 120), "fnval": "4048", "fnver": "0", "fourk": "1"]), provider: .bilibili, cookie: cookie)
        guard let play = root["data"] as? [String: Any], let dash = play["dash"] as? [String: Any],
              let videos = dash["video"] as? [[String: Any]], let audios = dash["audio"] as? [[String: Any]] else { throw CloudError.message("B 站没有返回音视频分轨。") }
        let supported = videos.filter {
            let codec = ($0["codecs"] as? String ?? "").lowercased()
            let id = ($0["codecid"] as? NSNumber)?.intValue ?? 0
            return id == 7 || id == 12 || codec.hasPrefix("avc1") || codec.hasPrefix("hev1") || codec.hasPrefix("hvc1")
        }
        let ids = Set(supported.compactMap { ($0["id"] as? NSNumber)?.intValue }.filter { $0 > 0 }).sorted(by: >)
        guard let actual = ids.first(where: { $0 <= (quality ?? Int.max) }) ?? ids.last else { throw CloudError.message("B 站没有适配的分轨画质。") }
        let matching = supported.filter { ($0["id"] as? NSNumber)?.intValue == actual }
        guard let video = matching.first(where: { ($0["codecid"] as? NSNumber)?.intValue == 7 || ($0["codecs"] as? String ?? "").hasPrefix("avc1") }) ?? matching.first else { throw CloudError.message("B 站视频轨道缺失。") }
        let aac = audios.filter {
            let codec = ($0["codecs"] as? String ?? "").lowercased()
            let id = ($0["id"] as? NSNumber)?.intValue ?? 0
            return codec.hasPrefix("mp4a") || (codec.isEmpty && [30216, 30232, 30280].contains(id))
        }
        guard let audio = aac.max(by: { (($0["bandwidth"] as? NSNumber)?.int64Value ?? 0) < (($1["bandwidth"] as? NSNumber)?.int64Value ?? 0) }) else { throw CloudError.message("B 站未返回适配的 AAC 音轨。") }
        func trackURL(_ track: [String: Any]) -> URL? {
            let primary = track["baseUrl"] as? String ?? track["base_url"] as? String
            let backup = track["backupUrl"] as? [String] ?? track["backup_url"] as? [String] ?? []
            let urls = ([primary].compactMap { $0 } + backup).compactMap(MediaNames.secureURL)
            return urls.first(where: { !($0.host ?? "").contains("mcdn") }) ?? urls.first
        }
        guard let videoURL = trackURL(video), let audioURL = trackURL(audio) else { throw CloudError.message("B 站分轨缺少下载地址。") }
        var preview: URL?
        do {
            let single = try await json(apiURL("/x/player/playurl", query: ["bvid": bvid, "cid": String(selected.cid), "qn": "80", "fnval": "1", "fnver": "0", "platform": "html5", "high_quality": "1"]), provider: .bilibili, cookie: cookie)
            if let segments = (single["data"] as? [String: Any])?["durl"] as? [[String: Any]], segments.count == 1, let raw = segments[0]["url"] as? String { preview = MediaNames.secureURL(raw) }
        } catch { try Task.checkCancellation() }
        let title = data["title"] as? String ?? bvid
        let name = MediaNames.filename(title, fallback: bvid) + (parts.count > 1 ? "_P\(selected.id)" : "")
        let asset = MediaAsset(id: "dash-\(selected.cid)-\(actual)", url: videoURL, previewURL: preview, filename: name + "_" + MediaNames.quality(actual) + ".mp4",
                               label: MediaNames.quality(actual) + " · DASH 合轨", size: nil, kind: .video,
                               headers: ["Referer": MediaProvider.bilibili.origin, "User-Agent": Self.userAgent], audioURL: audioURL)
        return MediaResult(title: title, author: (data["owner"] as? [String: Any])?["name"] as? String ?? "", source: URL(string: "https://www.bilibili.com/video/\(bvid)?p=\(selected.id)")!,
                           assets: [asset], parts: parts, qualities: ids.map { MediaQuality(id: $0, title: MediaNames.quality($0)) }, selectedPart: selected.id, actualQuality: actual)
    }

    private func pixiv(_ link: MediaLink, cookie: String) async throws -> MediaResult {
        let root = try await json("https://www.pixiv.net/ajax/illust/\(link.id)", provider: .pixiv, cookie: cookie)
        guard let info = root["body"] as? [String: Any] else { throw CloudError.message("Pixiv 作品信息为空。") }
        guard (info["illustType"] as? NSNumber)?.intValue != 2 else {
            throw CloudError.message("Pixiv ugoira 动图需要帧合成，当前版本尚未支持。")
        }
        let pages = try await json("https://www.pixiv.net/ajax/illust/\(link.id)/pages", provider: .pixiv, cookie: cookie)
        guard let list = pages["body"] as? [[String: Any]], !list.isEmpty, list.count <= 1000 else {
            throw CloudError.message("Pixiv 未返回有效原图列表，或作品超过当前 1000 页上限。")
        }
        let expected = (info["pageCount"] as? NSNumber)?.intValue
        if let expected, expected > 0, list.count != expected {
            throw CloudError.message("原图页数与作品记录不符，请重新解析，避免遗漏图片。")
        }
        let title = info["title"] as? String ?? "Pixiv_\(link.id)"
        let name = MediaNames.filename(title, fallback: "Pixiv_\(link.id)")
        let headers = ["User-Agent": Self.userAgent, "Referer": MediaProvider.pixiv.origin]
        let assets: [MediaAsset] = try list.enumerated().map { index, page in
            guard let urls = page["urls"] as? [String: Any], let original = urls["original"] as? String,
                  let url = MediaNames.secureURL(original) else {
                throw CloudError.message("部分页面缺少原图地址，未返回不完整的图集。")
            }
            let ext = url.pathExtension.lowercased()
            let suffix = ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) ? ext : "jpg"
            let thumbnail = ((urls["regular"] as? String) ?? (urls["small"] as? String)).flatMap(MediaNames.secureURL)
            return MediaAsset(id: "\(link.id)-\(index)", url: url, previewURL: thumbnail,
                              filename: "\(name)_\(index + 1).\(suffix)", label: "原图 \(index + 1)/\(list.count)",
                              size: nil, kind: .image, headers: headers)
        }
        return MediaResult(title: title, author: info["userName"] as? String ?? "",
                           source: URL(string: "https://www.pixiv.net/artworks/\(link.id)")!,
                           assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }

    private func apiURL(_ path: String, query: [String: String]) -> String {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.bilibili.com"; parts.path = path
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!.absoluteString
    }

    private func json(_ text: String, provider: MediaProvider, cookie: String) async throws -> [String: Any] {
        guard let url = URL(string: text) else { throw CloudError.message("无效的平台地址。") }
        let (data, response) = try await fetch(url, provider: provider, cookie: cookie)
        guard (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.message("平台请求失败（HTTP \(response.statusCode)），请检查网络或登录状态。")
        }
        if provider == .bilibili {
            guard let code = root["code"] as? NSNumber, code.intValue == 0 else {
                let code = (root["code"] as? NSNumber)?.intValue ?? -1
                throw CloudError.message("B 站拒绝请求（\(code)），请检查作品权限或重新登录。")
            }
        } else {
            guard root["error"] as? Bool == false else {
                throw CloudError.message("Pixiv 拒绝请求，作品可能不可见、已删除或需要有效登录。")
            }
        }
        return root
    }

    private func fetch(_ url: URL, provider: MediaProvider, cookie: String) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https" else { throw CloudError.message("不允许不安全的平台请求。") }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(provider.origin, forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let host = url.host?.lowercased() ?? ""
        if !cookie.isEmpty && (host == provider.domain || host.hasSuffix("." + provider.domain)) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudError.message("无效的平台响应。") }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw CloudError.message("平台连接失败，请检查网络后重试。")
        }
    }
}
