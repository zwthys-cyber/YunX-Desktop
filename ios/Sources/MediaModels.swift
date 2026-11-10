// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum MediaProvider: String, CaseIterable, Identifiable {
    case bilibili = "哔哩哔哩"
    case pixiv = "Pixiv"
    case weibo = "微博"
    case kuaishou = "快手"
    case acfun = "AcFun"
    case douyin = "抖音"
    case xhs = "小红书"
    var id: String { rawValue }
    var requiresBrowser: Bool { self == .douyin || self == .xhs }
    var supportsAccountValidation: Bool { self == .bilibili || self == .pixiv }
    var domain: String {
        switch self { case .bilibili: return "bilibili.com"; case .pixiv: return "pixiv.net"; case .weibo: return "weibo.com"; case .kuaishou: return "kuaishou.com"; case .acfun: return "acfun.cn"; case .douyin: return "douyin.com"; case .xhs: return "xiaohongshu.com" }
    }
    var origin: String { "https://www." + domain + "/" }
    var loginURL: URL {
        switch self {
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")!
        case .pixiv: return URL(string: "https://accounts.pixiv.net/login")!
        case .weibo: return URL(string: "https://passport.weibo.cn/signin/login")!
        case .kuaishou: return URL(string: "https://www.kuaishou.com/")!
        case .acfun: return URL(string: "https://www.acfun.cn/")!
        case .douyin: return URL(string: "https://www.douyin.com/")!
        case .xhs: return URL(string: "https://www.xiaohongshu.com/login")!
        }
    }
}

struct MediaLink: Equatable {
    let provider: MediaProvider
    let id: String
    let url: URL
    let part: Int
    let isShort: Bool
    var kind = ""

    static func parse(_ text: String) throws -> MediaLink {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, let parsed = parseURL(url) { return parsed }
        }
        throw CloudError.message("支持抖音、小红书、快手、微博、AcFun、B 站和 Pixiv 作品链接。")
    }

    static func parseURL(_ url: URL) -> MediaLink? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if ["b23.tv", "bili2233.cn"].contains(host), !path.isEmpty {
            return MediaLink(provider: .bilibili, id: "", url: url, part: 1, isShort: true)
        }
        if ["v.douyin.com", "www.douyin.com", "douyin.com", "www.iesdouyin.com", "iesdouyin.com"].contains(host) {
            if host == "v.douyin.com", path.count == 1 {
                return MediaLink(provider: .douyin, id: "", url: url, part: 1, isShort: false)
            }
            let tail = path.count >= 2 && ["video", "note", "slides"].contains(path[path.count - 2]) ? path.last : nil
            let modal = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "modal_id" })?.value
            if let id = tail ?? modal, id.range(of: "^[0-9]{5,25}$", options: .regularExpression) != nil {
                return MediaLink(provider: .douyin, id: id, url: url, part: 1, isShort: false)
            }
        }
        if ["xhslink.com", "www.xhslink.com"].contains(host), !path.isEmpty {
            return MediaLink(provider: .xhs, id: "", url: url, part: 1, isShort: false)
        }
        if ["xiaohongshu.com", "www.xiaohongshu.com"].contains(host), let id = path.last,
           id.range(of: "^[a-f0-9]{24}$", options: [.regularExpression, .caseInsensitive]) != nil,
           (path.count == 2 && path[0] == "explore" || path.count == 3 && path[0] == "discovery" && path[1] == "item") {
            return MediaLink(provider: .xhs, id: id, url: url, part: 1, isShort: false)
        }
        if ["acfun.cn", "www.acfun.cn", "m.acfun.cn"].contains(host), path.count == 2, path[0] == "v",
           path[1].range(of: "^ac[0-9]+$", options: .regularExpression) != nil {
            return MediaLink(provider: .acfun, id: String(path[1].dropFirst(2)), url: url, part: 1, isShort: false)
        }
        if KuaishouClient.allowed(host), let identifier = path.last,
           identifier.range(of: "^[0-9A-Za-z_-]{1,128}$", options: .regularExpression) != nil {
            let valid = (host == "v.kuaishou.com" && path.count == 1) ||
                (path.count >= 2 && ["short-video", "f"].contains(path[0])) ||
                (path.count == 3 && path[0] == "fw" && ["photo", "long-video"].contains(path[1]))
            if valid { return MediaLink(provider: .kuaishou, id: identifier, url: url, part: 1, isShort: false) }
        }
        if ["weibo.com", "www.weibo.com", "m.weibo.cn", "weibo.cn", "video.weibo.com", "h5.video.weibo.com"].contains(host) {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if path.count >= 3, path[0] == "tv", path[1] == "show", let mid = query.first(where: { $0.name == "mid" })?.value,
               mid.range(of: "^[0-9]{1,24}$", options: .regularExpression) != nil {
                return MediaLink(provider: .weibo, id: mid, url: url, part: 1, isShort: false, kind: "tv")
            }
            let fid = query.first(where: { $0.name == "fid" })?.value ?? (path.first == "show" && path.count == 2 ? path[1] : "")
            if fid.range(of: "^[0-9]+:[0-9]+$", options: .regularExpression) != nil {
                return MediaLink(provider: .weibo, id: fid, url: url, part: 1, isShort: false, kind: "fid")
            }
            if path.count == 2, ["status", "statuses", "detail"].contains(path[0]), path[1].range(of: "^[0-9A-Za-z]{1,24}$", options: .regularExpression) != nil {
                return MediaLink(provider: .weibo, id: path[1], url: url, part: 1, isShort: false, kind: "status")
            }
            if path.count == 2, path[0].allSatisfy(\.isNumber), path[1].range(of: "^[0-9A-Za-z]{6,24}$", options: .regularExpression) != nil {
                return MediaLink(provider: .weibo, id: path[1], url: url, part: 1, isShort: false, kind: "status")
            }
        }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
           path.count >= 2, path[0] == "video",
           path[1].range(of: #"^(BV[A-Za-z0-9]{10}|av[0-9]+)$"#, options: [.caseInsensitive, .regularExpression]) != nil {
            let partText = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value
            let part = partText.flatMap(Int.init) ?? 1
            guard part > 0 else { return nil }
            return MediaLink(provider: .bilibili, id: path[1], url: url, part: part, isShort: false)
        }
        if host == "pixiv.net" || host.hasSuffix(".pixiv.net") {
            let artwork = path.firstIndex(of: "artworks")
            if let artwork, path.count == artwork + 2,
               path[artwork + 1].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
                return MediaLink(provider: .pixiv, id: path[artwork + 1], url: url, part: 1, isShort: false)
            }
            if url.lastPathComponent == "member_illust.php",
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "illust_id" })?.value,
               id.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil {
                return MediaLink(provider: .pixiv, id: id, url: url, part: 1, isShort: false)
            }
        }
        return nil
    }
}

struct MediaPart: Identifiable {
    let id: Int
    let title: String
    let cid: Int64
}
struct MediaQuality: Identifiable {
    let id: Int
    let title: String
}
struct MediaAsset: Identifiable {
    enum Kind: Equatable { case video, image }
    let id: String
    let url: URL
    let previewURL: URL?
    let filename: String
    let label: String
    let size: Int64?
    let kind: Kind
    let headers: [String: String]
    var isHLS = false
    var audioURL: URL? = nil
    var livePhotoVideoURL: URL? = nil
}
struct MediaResult {
    let title: String
    let author: String
    let source: URL
    var assets: [MediaAsset]
    let parts: [MediaPart]
    let qualities: [MediaQuality]
    let selectedPart: Int
    let actualQuality: Int?
    var notice: String? = nil
    var concatenateSegments = false
}

enum MediaNames {
    static func filename(_ text: String, fallback: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileNamePolicy.name(value.isEmpty || value == "." || value == ".." ? fallback : value, maxBytes: 160)
    }

    static func secureURL(_ text: String) -> URL? {
        let normalized: String
        if text.hasPrefix("//") { normalized = "https:" + text }
        else if text.lowercased().hasPrefix("http://") { normalized = "https://" + String(text.dropFirst(7)) }
        else { normalized = text }
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func quality(_ number: Int) -> String {
        switch number {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        default: return "画质 \(number)"
        }
    }
}
