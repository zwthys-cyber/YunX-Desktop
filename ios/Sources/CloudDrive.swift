// SPDX-License-Identifier: AGPL-3.0-only
// Protocol behavior ported from the repository's QuarkApi.kt / UCApi.kt.
import Foundation

enum CloudProvider: String, CaseIterable, Identifiable {
    case quark = "夸克"
    case uc = "UC"
    case pan123 = "123"
    case guangya = "光鸭"
    case ilanzou = "蓝奏优享"
    case xunlei = "迅雷"
    case baidu = "百度"
    case c139 = "139"
    case pan115 = "115"
    var supportsWebCookieLogin: Bool { self == .quark || self == .uc || self == .baidu || self == .c139 || self == .pan115 }
    var supportsManagement: Bool { [CloudProvider.quark, .uc, .pan123, .guangya, .ilanzou, .xunlei, .baidu, .c139, .pan115].contains(self) }
    var id: String { rawValue }
    var apiHost: String {
        switch self { case .quark: return "drive-pc.quark.cn"; case .uc: return "pc-api.uc.cn"; case .pan123: return "yun.123pan.cn"; case .guangya: return "api.guangyapan.com"; case .ilanzou: return "apis.ilanzou.com"; case .xunlei: return "api-pan.xunlei.com"; case .baidu: return "pan.baidu.com"; case .c139: return "personal-kd-njs.yun.139.com"; case .pan115: return "webapi.115.com" }
    }
    var webHost: String {
        switch self { case .quark: return "pan.quark.cn"; case .uc: return "drive.uc.cn"; case .pan123: return "www.123pan.com"; case .guangya: return "www.guangyapan.com"; case .ilanzou: return "www.ilanzou.com"; case .xunlei: return "pan.xunlei.com"; case .baidu: return "pan.baidu.com"; case .c139: return "yun.139.com"; case .pan115: return "115.com" }
    }
    var cookieDomain: String {
        switch self { case .quark: return "quark.cn"; case .uc: return "uc.cn"; case .pan123: return "123pan.cn"; case .guangya: return "guangyapan.com"; case .ilanzou: return "ilanzou.com"; case .xunlei: return "xunlei.com"; case .baidu: return "baidu.com"; case .c139: return "139.com"; case .pan115: return "115.com" }
    }
    func acceptsShareHost(_ host: String) -> Bool {
        if self == .pan115 { return ["115.com", "115cdn.com", "115rc.com", "www.115.com", "www.115cdn.com", "www.115rc.com"].contains(host) }
        if self == .ilanzou { return ["ilanzou.com", "www.ilanzou.com", "ilanzou.net", "www.ilanzou.net", "ilanzou.org", "www.ilanzou.org", "ilanzou.cn", "www.ilanzou.cn"].contains(host) }
        if self == .guangya { return host == "www.guangyapan.com" || host == "guangyapan.com" }
        if self == .pan123 { return ["www.123pan.com", "123pan.com", "www.123865.com", "123865.com", "www.123684.com", "123684.com", "www.123912.com", "123912.com", "www.123pan.cn", "yun.123pan.cn"].contains(host) }
        return host == webHost
    }
    var origin: String { "https://" + webHost }
    var loginURL: URL { URL(string: origin + (self == .c139 ? "/m/#/login" : "/"))! }
    var userAgent: String {
        if self == .pan115 { return Pan115Client.webAgent }
        if self == .c139 { return C139Protocol.mobileAgent }
        if self == .baidu { return BaiduClient.webAgent }
        if self == .xunlei { return XunleiProtocol.webAgent }
        if self == .quark {
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"
        }
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
    var guestAgent: String {
        self == .quark ? userAgent :
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    }
}

struct CloudShare: Equatable {
    let provider: CloudProvider
    let shareID: String
    let passcode: String

    static func parse(_ text: String, override: String = "") throws -> CloudShare {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  let provider = CloudProvider.allCases.first(where: { $0.acceptsShareHost(url.host?.lowercased() ?? "") }) else { continue }
            if provider == .pan115 {
                let parts = url.path.split(separator: "/")
                let raw = parts.count == 2 && parts[0] == "s" ? String(parts[1]) : (parts.count == 1 ? String(parts[0]) : "")
                let components = raw.split(separator: "-", maxSplits: 1).map(String.init)
                guard let id = components.first, id.range(of: "^sw[A-Za-z0-9]+$", options: .regularExpression) != nil else { continue }
                let queryCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { ["password", "pwd"].contains($0.name.lowercased()) })?.value
                let regex = try NSRegularExpression(pattern: #"(?:提取码|访问码|密码)\s*[：:]?\s*([A-Za-z0-9]{4,8})"#)
                let textCode = regex.firstMatch(in: text, range: range).flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) }
                let manual = override.trimmingCharacters(in: .whitespacesAndNewlines)
                return CloudShare(provider: provider, shareID: id, passcode: manual.isEmpty ? (queryCode ?? (components.count == 2 ? components[1] : nil) ?? textCode ?? "") : manual)
            }
            if provider == .c139 {
                let fragment = url.fragment ?? ""
                let components = fragment.split(separator: "?").first.map(String.init) ?? ""
                let parts = components.split(separator: "/")
                guard url.path.hasPrefix("/shareweb/"), parts.count == 3, parts[0] == "w", parts[1] == "i", parts[2].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { continue }
                let query = URLComponents(string: "https://yun.139.com/?" + (fragment.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""))?.queryItems
                let fromQuery = query?.first(where: { ["password", "passwd", "pwd"].contains($0.name.lowercased()) })?.value ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { ["password", "passwd", "pwd"].contains($0.name.lowercased()) })?.value
                let regex = try NSRegularExpression(pattern: #"(?:提取码|访问码|密码)\s*[：:]?\s*([A-Za-z0-9]{4,8})"#)
                let matched = regex.firstMatch(in: text, range: range).flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) }
                let manual = override.trimmingCharacters(in: .whitespacesAndNewlines)
                return CloudShare(provider: provider, shareID: String(parts[2]), passcode: manual.isEmpty ? (fromQuery ?? matched ?? "") : manual)
            }
            let parts = url.path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "s",
                  parts[1].range(of: [CloudProvider.pan123, .guangya, .ilanzou, .xunlei, .baidu].contains(provider) ? "^[A-Za-z0-9_-]+$" : "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { continue }
            if provider == .baidu && (!parts[1].hasPrefix("1") || parts[1].count < 2) { continue }
            let queryCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name.lowercased() == "pwd" || (provider == .guangya && $0.name.lowercased() == "code") })?.value
            let pattern = #"(?:提取码|访问码|密码)\s*[：:]?\s*([A-Za-z0-9]{4,8})"#
            let regex = try NSRegularExpression(pattern: pattern)
            let codeMatch = regex.firstMatch(in: text, range: range)
            let textCode = codeMatch.flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) }
            let manual = override.trimmingCharacters(in: .whitespacesAndNewlines)
            return CloudShare(provider: provider, shareID: String(parts[1]),
                              passcode: manual.isEmpty ? (queryCode ?? textCode ?? "") : manual)
        }
        throw CloudError.message("目前支持夸克、UC、123、光鸭、蓝奏优享、迅雷、百度、139 和 115 分享链接，请粘贴完整的 https://…/s/… 链接。")
    }
}

struct CloudFile: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    let isDirectory: Bool
    let parentID: String
    let token: String
}

struct CloudDownload {
    let url: URL
    let filename: String
    let size: Int64
    let headers: [String: String]
}

struct CloudPage {
    let files: [CloudFile]
    let hasMore: Bool
}

enum CloudError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

enum CloudNamePolicy {
    static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CloudError.message("文件名称为空、过长或含无效字符。") }
    }
}

/// API requests never follow redirects with account credentials.
private final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class CloudClient {
    let provider: CloudProvider
    private(set) var cookie: String
    private var guestCookie = ""
    private var pan123: Pan123Client?
    private var guangya: GuangYaClient?
    private var ilanzou: ILanzouClient?
    private var xunlei: XunleiClient?
    private var baidu: BaiduClient?
    private var c139: C139Client?
    private var pan115: Pan115Client?
    private let session: URLSession
    private let cookieChanged: ((String) -> Void)?
    private var tokens: [CloudShareKey: String] = [:]
    private struct CloudShareKey: Hashable { let id: String; let code: String }

    init(provider: CloudProvider, cookie: String = "", fields: [String: String] = [:], session: URLSession? = nil,
         credentialChanged: ((String, [String: String]) -> Bool)? = nil, cookieChanged: ((String) -> Void)? = nil) {
        self.provider = provider
        self.cookie = cookie
        self.cookieChanged = cookieChanged
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: CloudRedirectPolicy(), delegateQueue: nil)
        }
        if provider == .pan123 { pan123 = Pan123Client(token: cookie, session: self.session) }
        if provider == .guangya { guangya = GuangYaClient(token: cookie, fields: fields, session: self.session, changed: credentialChanged) }
        if provider == .ilanzou { ilanzou = ILanzouClient(token: cookie, fields: fields, session: self.session) }
        if provider == .pan115 { pan115 = Pan115Client(cookie: cookie, session: self.session) }
        if provider == .c139 { c139 = C139Client(cookie: cookie, fields: fields, session: self.session) }
        if provider == .baidu { baidu = BaiduClient(cookie: cookie, session: self.session, changed: cookieChanged) }
        if provider == .xunlei { xunlei = XunleiClient(token: cookie, fields: fields, session: self.session, changed: credentialChanged) }
    }

    deinit { session.invalidateAndCancel() }

    func validateAccount() async throws -> String {
        if let pan115 { return try await pan115.validate() }
        if let c139 { return try await c139.validate() }
        if let baidu { let name = try await baidu.validate(); cookie = baidu.cookie; return name }
        if let xunlei { return try await xunlei.validate() }
        if let ilanzou { return try await ilanzou.validate() }
        if let guangya { return try await guangya.validate() }
        if let pan123 { return try await pan123.validate() }
        guard !cookie.isEmpty else { throw CloudError.message("请先登录或输入 Cookie。") }
        var request = URLRequest(url: URL(string: provider.origin + "/account/info")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(provider.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let account = root["data"] as? [String: Any],
              let nickname = account["nickname"] as? String, !nickname.isEmpty else {
            throw CloudError.message("登录尚未完成或 Cookie 已失效，请完成登录后重试。")
        }
        mergeResponseCookies(http, guest: false)
        return nickname
    }

    func mutate(_ operation: CloudMutation) async throws {
        if let pan115 { try await pan115.mutate(operation); return }
        if let c139 { try await c139.mutate(operation); return }
        if let baidu { try await baidu.mutate(operation); return }
        if let xunlei { try await xunlei.mutate(operation); return }
        if let pan123 { try await pan123.mutate(operation); return }
        if let ilanzou { try await ilanzou.mutate(operation); return }
        if let guangya { try await guangya.mutate(operation); return }
        guard provider == .quark || provider == .uc, !cookie.isEmpty else { throw CloudError.message("请先登录支持文件管理的平台。") }
        let path: String
        let body: [String: Any]
        switch operation {
        case .createFolder(let name, let parent):
            try CloudNamePolicy.validate(name)
            path = "/1/clouddrive/file"
            body = ["pdir_fid": parent, "file_name": name, "dir_path": "", "dir_init_lock": false]
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            path = "/1/clouddrive/file/rename"; body = ["fid": file.id, "file_name": name]
        case .move(let file, let parent):
            guard file.id != parent else { throw CloudError.message("不能将文件夹移动到自身。") }
            path = "/1/clouddrive/file/move"
            body = ["action_type": 1, "to_pdir_fid": parent, "filelist": [file.id], "exclude_fids": [String]()]
        case .trash(let file):
            path = "/1/clouddrive/file/delete"
            body = ["action_type": 2, "filelist": [file.id], "exclude_fids": [String]()]
        case .save(let file, let share, let parent):
            guard !file.token.isEmpty else { throw CloudError.message("分享文件令牌缺失，请重新解析。") }
            let token = try await shareToken(share)
            path = "/1/clouddrive/share/sharepage/save"
            body = ["pwd_id": share.shareID, "stoken": token, "pdir_fid": file.parentID, "to_pdir_fid": parent,
                    "fid_list": [file.id], "fid_token_list": [file.token], "scene": "link"]
        }
        let data = try await request(path, body: body, allowEmptyData: true) as? [String: Any] ?? [:]
        if case .createFolder = operation {
            guard let id = data["fid"] as? String, !id.isEmpty else { throw CloudError.message("平台未确认创建文件夹，请刷新后确认。") }
        }
        if let id = data["task_id"] as? String, !id.isEmpty { try await waitForMutation(id) }
    }
    private func waitForMutation(_ id: String) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            let data = try await request("/1/clouddrive/task", query: ["task_id": id, "retry_index": "0"]) as? [String: Any] ?? [:]
            let status = (data["status"] as? NSNumber)?.intValue ?? (data["task_status"] as? NSNumber)?.intValue
            if status == 3 { throw CloudError.message("平台文件操作失败，请刷新确认。") }
            if status == 2 || ((data["finished_at"] as? NSNumber)?.int64Value ?? 0) > 0 { return }
        }
        throw CloudError.message("平台操作仍在处理中，请刷新确认，避免重复提交。")
    }

    private func shareToken(_ share: CloudShare) async throws -> String {
        guard share.provider == provider else { throw CloudError.message("分享平台与当前账号不一致。") }
        let key = CloudShareKey(id: share.shareID, code: share.passcode)
        if let token = tokens[key] { return token }
        var body: [String: Any] = ["pwd_id": share.shareID, "passcode": share.passcode]
        body[provider == .quark ? "support_visit_limit_private_share" : "share_for_transfer"] = true
        let data = try await request("/1/clouddrive/share/sharepage/token", body: body) as? [String: Any]
        guard let token = data?["stoken"] as? String, !token.isEmpty else {
            throw CloudError.message("分享未返回访问令牌，请检查提取码。")
        }
        tokens[key] = token
        return token
    }

    func list(share: CloudShare?, parentID: String = "0", page: Int = 1) async throws -> [CloudFile] {
        if let pan115 { return try await pan115.list(share: share, parent: parentID, page: page) }
        if let c139 { return try await c139.list(share: share, parent: parentID, page: page) }
        if let baidu { return try await baidu.list(share: share, parent: parentID, page: page) }
        if let xunlei { return try await xunlei.list(share: share, parent: parentID, page: page) }
        if let ilanzou { return try await ilanzou.list(share: share, parent: parentID, page: page) }
        if let guangya { return try await guangya.list(share: share, parent: parentID, page: page) }
        if let pan123 { return try await pan123.list(share: share, parent: parentID, page: page) }
        guard page >= 1 else { throw CloudError.message("分页参数无效。") }
        var query = ["pdir_fid": parentID, "_page": String(page), "_size": "50",
                     "_fetch_total": "1", "_sort": "file_type:asc,file_name:asc"]
        let result: Any
        if let share {
            let token = try await shareToken(share)
            query["pwd_id"] = share.shareID
            query["stoken"] = token
            if provider == .quark {
                query.merge(["ver": "2", "force": "0", "_fetch_banner": "0",
                             "_fetch_share": "0", "fetch_relate_conversation": "0"]) { _, new in new }
                result = try await request("/1/clouddrive/share/sharepage/detail", query: query)
            } else {
                query.merge(["entry": "ft", "fetch_file_list": "1", "passcode": "",
                             "_fetch_task": "1", "_fetch_share": "1", "_sort": ""]) { _, new in new }
                result = try await request("/1/clouddrive/transfer_share/detail", query: query,
                                           origin: "https://fast.uc.cn")
            }
        } else {
            guard !cookie.isEmpty else { throw CloudError.message("浏览个人网盘需要选择已登录账号。") }
            query["_fetch_sub_dirs"] = "0"
            query["fetch_all_file"] = "1"
            result = try await request("/1/clouddrive/file/sort", query: query,
                                      agent: provider == .uc ? ucCloudAgent : nil)
        }
        guard let data = result as? [String: Any],
              let list = (data["list"] as? [[String: Any]]) ??
                ((data["detail_info"] as? [String: Any])?["list"] as? [[String: Any]]) else {
            throw CloudError.message("服务端未返回文件列表，可能需要更新平台适配。")
        }
        return try list.map { item in
            guard let id = item["fid"] as? String, !id.isEmpty,
                  let name = [item["file_name"], item["fname"]].compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { throw CloudError.message("平台文件条目信息不完整，已停止显示该页以免遗漏。") }
            let directory = (item["dir"] as? Bool) == true || (item["isdir"] as? NSNumber)?.intValue == 1
            let rawSize = item["size"] ?? item["fsize"]
            let size = (rawSize as? NSNumber)?.int64Value ?? Int64(rawSize as? String ?? "") ?? 0
            guard size >= 0 else { throw CloudError.message("平台文件大小无效，已停止显示该页。") }
            return CloudFile(id: id, name: name, size: size,
                             isDirectory: directory, parentID: item["pdir_fid"] as? String ?? parentID,
                             token: item["share_fid_token"] as? String ?? item["fid_token"] as? String ?? "")
        }
    }

    func listPage(share: CloudShare?, parentID: String = "0", page: Int = 1) async throws -> CloudPage {
        let files = try await list(share: share, parentID: parentID, page: page)
        let more: Bool
        if let pan115 { more = pan115.hasMore(share: share, parent: parentID, page: page) }
        else if let c139 { more = c139.hasMore(share: share, parent: parentID, page: page) }
        else if let baidu { more = baidu.hasMore(share: share, parent: parentID, page: page) }
        else if let xunlei { more = xunlei.hasMore(share: share, parent: parentID, page: page) }
        else if let pan123 { more = pan123.hasMore(share: share, parent: parentID, page: page) }
        else if let guangya { more = guangya.hasMore(share: share, parent: parentID, page: page) }
        else if let ilanzou { more = ilanzou.hasMore(share: share, parent: parentID, page: page, count: files.count) }
        else { more = files.count >= 50 }
        guard !more || !files.isEmpty else { throw CloudError.message("平台返回空页但仍声明有后续，已停止以免遗漏文件。") }
        return CloudPage(files: files, hasMore: more)
    }

    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        if let pan115 { return try await pan115.download(file: file, share: share) }
        if let c139 { return try await c139.download(file: file, share: share) }
        if let baidu { return try await baidu.download(file: file, share: share) }
        if let xunlei { return try await xunlei.download(file: file, share: share) }
        if let ilanzou { return try await ilanzou.download(file: file, share: share) }
        if let guangya { return try await guangya.download(file: file, share: share) }
        if let pan123 { return try await pan123.download(file: file, share: share) }
        guard !file.isDirectory else { throw CloudError.message("请进入文件夹后选择文件下载。") }
        var body: [String: Any] = ["fids": [file.id]]
        var query: [String: String] = [:]
        let guest = cookie.isEmpty
        if let share {
            guard !file.token.isEmpty else { throw CloudError.message("文件令牌缺失，请重新解析分享。") }
            body["pwd_id"] = share.shareID
            body["stoken"] = try await shareToken(share)
            body["fids_token"] = [file.token]
            if provider == .quark {
                body["speedup_session"] = ""
                body["token"] = ""
            } else { query["entry"] = "ft" }
        } else {
            guard !guest else { throw CloudError.message("下载个人网盘文件需要登录。") }
        }
        if provider == .quark { query.merge(["sys": "win32", "ve": "3.23.2"]) { _, new in new } }
        else if share == nil { query.merge(["sys": "win32", "ve": "1.6.1"]) { _, new in new } }
        let result = try await request("/1/clouddrive/file/download", query: query, body: body,
                                       guest: guest, agent: guest ? provider.guestAgent :
                                        (provider == .uc && share == nil ? ucCloudAgent : nil))
        guard let list = result as? [[String: Any]], let first = list.first,
              let text = first["download_url"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw CloudError.message("服务端未返回安全的下载直链。")
        }
        var headers = ["User-Agent": guest ? provider.guestAgent : provider.userAgent,
                       "Referer": provider.origin + "/"]
        let downloadCookie = guest ? guestCookie : cookie
        if !downloadCookie.isEmpty { headers["Cookie"] = downloadCookie }
        if provider == .uc && guest {
            headers["Sec-Ch-Ua"] = #""Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100""#
        }
        return CloudDownload(url: url, filename: first["file_name"] as? String ?? file.name,
                             size: (first["size"] as? NSNumber)?.int64Value ?? file.size, headers: headers)
    }

    private var ucCloudAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
    }

    private func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                         guest: Bool = false, origin: String? = nil, agent: String? = nil, allowEmptyData: Bool = false) async throws -> Any {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = provider.apiHost
        parts.path = path
        var values = ["pr": provider == .quark ? "ucpro" : "UCBrowser", "fr": "pc"]
        values.merge(query) { _, new in new }
        parts.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw CloudError.message("请求地址无效。") }
        var request = URLRequest(url: url)
        let requestCookie = guest ? guestCookie : cookie
        if !requestCookie.isEmpty { request.setValue(requestCookie, forHTTPHeaderField: "Cookie") }
        request.setValue(agent ?? provider.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin ?? provider.origin, forHTTPHeaderField: "Origin")
        request.setValue((origin ?? provider.origin) + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .uc && guest {
            request.setValue(#""Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100""#,
                             forHTTPHeaderField: "Sec-Ch-Ua")
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw CloudError.message("网络连接失败，请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("无效的服务器响应。") }
        mergeResponseCookies(http, guest: guest)
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.message("平台请求失败（HTTP \(http.statusCode)）。")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.message("平台返回了非 JSON 响应，可能触发了登录验证或风控。")
        }
        let status = (root["status"] as? NSNumber)?.intValue
        let code = (root["code"] as? NSNumber)?.intValue
        guard (status == 200 && (code == nil || code == 0)) || (status == nil && code == 0) else {
            let description: String
            switch code {
            case 31001: description = "需要登录或账号已失效，请重新登录。"
            case 23018: description = "文件超出游客限制，请选择已登录账号重试。"
            case 14001: description = "分享已失效或提取码错误。"
            case 41020:
                tokens.removeAll()
                description = "文件令牌已过期，请重新解析分享。"
            default: description = "平台拒绝请求（状态 \(status ?? -1)，错误码 \(code ?? -1)），请检查分享和账号。"
            }
            throw CloudError.message(description)
        }
        if let result = root["data"], !(result is NSNull) { return result }
        if allowEmptyData { return [String: Any]() }
        throw CloudError.message("平台未返回数据，可能需要重新登录或更新适配。")
    }

    private func mergeResponseCookies(_ response: HTTPURLResponse, guest: Bool) {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        let allowed: Set<String> = guest ? ["__pugs"] : ["__pus", "__puus"]
        var values: [String: String] = [:]
        for pair in (guest ? guestCookie : cookie).split(separator: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        for item in received where allowed.contains(item.name) {
            if let expiry = item.expiresDate, expiry <= Date() { values.removeValue(forKey: item.name) }
            else { values[item.name] = item.value }
        }
        let merged = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        if guest { guestCookie = merged }
        else if !cookie.isEmpty && merged != cookie { cookie = merged; cookieChanged?(merged) }
    }
}
