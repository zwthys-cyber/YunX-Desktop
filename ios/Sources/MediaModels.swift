// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum MediaProvider: String, CaseIterable, Identifiable {
    case bilibili = "哔哩哔哩"
    case pixiv = "Pixiv"
    var id: String { rawValue }
    var domain: String { self == .bilibili ? "bilibili.com" : "pixiv.net" }
    var origin: String { "https://www." + domain + "/" }
    var loginURL: URL {
        URL(string: self == .bilibili ? "https://passport.bilibili.com/login" : "https://accounts.pixiv.net/login")!
    }
}

struct MediaLink: Equatable {
    let provider: MediaProvider
    let id: String
    let url: URL
    let part: Int
    let isShort: Bool

    static func parse(_ text: String) throws -> MediaLink {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, let parsed = parseURL(url) { return parsed }
        }
        throw CloudError.message("目前支持 B 站视频链接、b23 短链和 Pixiv 作品链接。")
    }

    static func parseURL(_ url: URL) -> MediaLink? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if ["b23.tv", "bili2233.cn"].contains(host), !path.isEmpty {
            return MediaLink(provider: .bilibili, id: "", url: url, part: 1, isShort: true)
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
}
struct MediaResult {
    let title: String
    let author: String
    let source: URL
    let assets: [MediaAsset]
    let parts: [MediaPart]
    let qualities: [MediaQuality]
    let selectedPart: Int
    let actualQuality: Int?
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
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
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
