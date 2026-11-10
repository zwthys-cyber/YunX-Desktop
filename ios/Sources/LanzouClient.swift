// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor
final class LanzouClient {
    private struct Page {
        let url: URL; let html: String; let title: String; let folder: Bool
        let parameters: [String: String]
    }
    private let session: URLSession
    private(set) var cookie: String
    private let changed: ((String) -> Void)?
    private var uid = "", vei = ""
    private var jar: [String: [String: String]] = [:]
    private var pages: [String: Page] = [:]
    private var more: [String: [Int: Bool]] = [:]
    init(cookie: String, session: URLSession, changed: ((String) -> Void)?) { self.cookie = cookie; self.session = session; self.changed = changed }
    private func key(_ share: CloudShare?, _ parent: String) -> String { (share.map { ($0.sourceURL?.absoluteString ?? $0.shareID) + "|" + $0.passcode } ?? "personal") + "|" + parent }
    private func root(_ parent: String) throws -> String { try LanzouProtocol.rawID(parent == "0" || parent.isEmpty ? "-1" : parent) }
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool {
        let parent = share == nil ? ((try? root(parent)) ?? parent) : parent
        return more[key(share, parent)]?[page] ?? false
    }
    func validate() async throws -> String {
        let values = LanzouProtocol.cookies(cookie)
        guard values["ylogin"]?.isEmpty == false, values["phpdisk_info"]?.isEmpty == false else { throw CloudError.message("蓝奏登录态不完整，请在官网完成登录。") }
        let url = URL(string: "https://pc.woozooo.com/mydisk.php?item=files&action=index")!
        let (data, _) = try await fetch(url, account: true)
        let html = String(decoding: data, as: UTF8.self)
        guard let id = LanzouProtocol.first(#"\buid['"]?\s*[=:]\s*['"]?([0-9]{1,20})"#, in: html), let value = LanzouProtocol.first(#"\bvei['"]?\s*[=:]\s*['"]?([A-Za-z0-9_+/=\-]{1,256})"#, in: html) else { throw CloudError.message("蓝奏登录已失效或要求官网验证。") }
        uid = id; vei = value
        return "蓝奏账号 " + String(id.suffix(4))
    }
    private func parameters() async throws { if uid.isEmpty || vei.isEmpty { _ = try await validate() } }
    private func personal(_ fields: [String: String], allowEnd: Bool = false) async throws -> [String: Any] {
        try await parameters()
        var parts = URLComponents(string: "https://pc.woozooo.com/doupload.php")!; parts.percentEncodedQuery = FormEncoding.query(["uid": uid, "vei": vei])
        let (data, _) = try await fetch(parts.url!, form: fields, account: true)
        let result = try json(data), status = Self.string(result["zt"])
        guard status == "1" || (status == "2" && allowEnd) else { throw CloudError.message("蓝奏操作失败（状态 \(status)），请确认登录、权限和请求频率。") }
        return result
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page), share == nil || share?.provider == .lanzou else { throw CloudError.message("蓝奏平台或分页参数无效。") }
        if let share {
            let key = key(share, parent)
            if page == 1 { more[key] = [:] }
            let info = try await resolve(share, refresh: page == 1)
            if !info.folder {
                more[key]?[page] = false
                return page == 1 ? [CloudFile(id: share.shareID, name: info.title, size: LanzouProtocol.size(LanzouProtocol.first(#"(?:文件大小|大小)\s*[:：]\s*([0-9.]+\s*[KMGT]?)"#, in: info.html) ?? ""), isDirectory: false, parentID: parent, token: "")] : []
            }
            guard !info.parameters.isEmpty else { throw CloudError.message("蓝奏分享分页参数缺失，请重新打开或在官网完成验证。") }
            var fields = info.parameters; fields["pwd"] = share.passcode; fields["pg"] = String(page)
            let target = URL(string: "/filemoreajax.php", relativeTo: info.url)!.absoluteURL
            let (raw, _) = try await fetch(target, form: fields, referer: info.url)
            let result = try json(raw), status = Self.string(result["zt"])
            if status == "2" { more[key]?[page] = false; return [] }
            guard status == "1" else { throw CloudError.message("蓝奏分享拒绝请求，请确认提取码和访问频率。") }
            guard let rows = result["text"] as? [[String: Any]] else { throw CloudError.message("蓝奏分享未返回文件列表。") }
            more[key]?[page] = !rows.isEmpty
            return try rows.map { try file($0, parent: parent, directory: false, personal: false) }
        }
        let parent = try root(parent), key = key(nil, try root(parent))
        if page == 1 { more[key] = [:] }
        var files = [CloudFile]()
        if page == 1 {
            let result = try await personal(["task": "47", "folder_id": parent], allowEnd: true)
            if Self.string(result["zt"]) == "1" {
                guard let rows = result["text"] as? [[String: Any]] else { throw CloudError.message("蓝奏未返回文件夹列表。") }
                files = try rows.map { try file($0, parent: parent, directory: true, personal: true) }
            }
        }
        let result = try await personal(["task": "5", "folder_id": parent, "pg": String(page)], allowEnd: true)
        let rows: [[String: Any]]
        if Self.string(result["zt"]) == "2" { rows = [] }
        else { guard let data = result["text"] as? [[String: Any]] else { throw CloudError.message("蓝奏未返回文件列表。") }; rows = data }
        more[key]?[page] = !rows.isEmpty
        return files + (try rows.map { try file($0, parent: parent, directory: false, personal: true) })
    }
    private func file(_ row: [String: Any], parent: String, directory: Bool, personal: Bool) throws -> CloudFile {
        let rawID = directory ? Self.string(row["fol_id"]).nonempty ?? Self.string(row["id"]) : Self.string(row["id"])
        let name = Self.string(row["name_all"]).nonempty ?? Self.string(row["name"])
        guard !rawID.isEmpty, !name.isEmpty else { throw CloudError.message("蓝奏文件信息不完整。") }
        if personal { _ = try LanzouProtocol.rawID(rawID) }
        return CloudFile(id: personal ? (directory ? "d:" : "f:") + rawID : rawID, name: name, size: directory ? 0 : LanzouProtocol.size(Self.string(row["size"])), isDirectory: directory, parentID: parent, token: "")
    }
    private func shareURL(_ share: CloudShare) throws -> URL {
        guard share.provider == .lanzou, let url = share.sourceURL ?? URL(string: "https://pan.lanzoui.com/" + share.shareID), LanzouProtocol.safe(url), LanzouProtocol.shareHost(url.host!) else { throw CloudError.message("蓝奏分享地址无效。") }
        return url
    }
    private func resolve(_ share: CloudShare, refresh: Bool = false) async throws -> Page {
        let url = try shareURL(share), key = url.absoluteString + "|" + share.passcode
        if !refresh, let page = pages[key] { return page }
        var current = url
        var seen = Set<URL>()
        for _ in 0..<8 {
            guard seen.insert(current).inserted else { throw CloudError.message("蓝奏分享页面循环跳转。") }
            let (data, response) = try await fetch(current)
            if (300..<400).contains(response.statusCode) {
                guard let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: current)?.absoluteURL, LanzouProtocol.safe(next), LanzouProtocol.shareHost(next.host!) else { throw CloudError.message("蓝奏分享跳转地址无效。") }; current = next; continue
            }
            guard response.statusCode == 200 else { throw CloudError.message("蓝奏分享失效或暂时无法访问。") }
            let html = String(decoding: data, as: UTF8.self)
            guard !html.contains("文件已取消"), !html.contains("文件不存在") else { throw CloudError.message("蓝奏分享已取消或不存在。") }
            if share.passcode.isEmpty, html.contains("请输入密码") || html.contains("input_password") { throw CloudError.message("蓝奏分享需要提取码。") }
            let isFolder = ["filemoreajax", "file_more", "class=\"filemore\""].contains { html.contains($0) }
            let title = (LanzouProtocol.first(#"<title>([^<]*)</title>"#, in: html) ?? LanzouProtocol.variable("filename", html: html) ?? "蓝奏分享").replacingOccurrences(of: " - 蓝奏云", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            var fields: [String: String] = [:]
            if isFolder, let lx = LanzouProtocol.variable("lx", html: html), let t = LanzouProtocol.variable("t", html: html), let k = LanzouProtocol.variable("k", html: html) { fields = ["lx": lx, "fid": LanzouProtocol.variable("fid", html: html) ?? share.shareID, "t": t, "k": k] }
            let page = Page(url: current, html: html, title: title.isEmpty ? "蓝奏分享" : title, folder: isFolder, parameters: fields)
            pages[key] = page; return page
        }
        throw CloudError.message("蓝奏分享跳转过多，请重新解析。")
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory else { throw CloudError.message("请先进入文件夹。") }
        let active: CloudShare
        if let share { active = share }
        else {
            // The UI explicitly asks before this creates a public share link.
            let result = try await personal(["task": "22", "file_id": try LanzouProtocol.rawID(file.id)])
            guard let info = result["info"] as? [String: Any] else { throw CloudError.message("蓝奏未返回文件分享信息。") }
            let raw = Self.string(info["f_id"]), domain = Self.string(info["is_newd"])
            let base = domain.isEmpty ? "https://pan.lanzoui.com" : (domain.contains("://") ? domain : "https://" + domain)
            guard let url = URL(string: raw.contains("://") ? raw : base + "/" + raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), LanzouProtocol.safe(url), LanzouProtocol.shareHost(url.host!) else { throw CloudError.message("蓝奏返回的分享地址无效。") }
            active = CloudShare(provider: .lanzou, shareID: url.lastPathComponent, passcode: Self.string(info["pwd"]), sourceURL: url)
        }
        var page = try await resolve(active, refresh: true)
        if page.folder {
            guard file.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, let url = URL(string: "/" + file.id, relativeTo: page.url)?.absoluteURL else { throw CloudError.message("蓝奏分享文件标识无效。") }
            page = try await resolve(CloudShare(provider: .lanzou, shareID: file.id, passcode: active.passcode, sourceURL: url), refresh: true)
        }
        var html = page.html
        if let frame = LanzouProtocol.first(#"<iframe\b[^>]+src=['"]([^'"]+)['"]"#, in: html) {
            guard let url = URL(string: frame, relativeTo: page.url)?.absoluteURL, LanzouProtocol.safe(url), url.host?.lowercased() == page.url.host?.lowercased() else { throw CloudError.message("蓝奏下载 iframe 不是同源地址。") }
            let (data, response) = try await fetch(url, referer: page.url)
            guard response.statusCode == 200 else { throw CloudError.message("蓝奏下载页无法访问。") }; html = String(decoding: data, as: UTF8.self)
        }
        guard let id = LanzouProtocol.first(#"(?:ajaxm|ajaxfile)\.php\?file=([0-9]+)"#, in: html) ?? LanzouProtocol.first(#"\bfile=([0-9]+)"#, in: html), let sign = LanzouProtocol.variable("wp_sign", html: html) ?? LanzouProtocol.variable("sign", html: html) ?? LanzouProtocol.input("sign", html: html) else { throw CloudError.message("蓝奏下载页缺少必要参数，请在官网完成验证后重新解析。") }
        let candidate = [LanzouProtocol.variable("domain1", html: html), LanzouProtocol.variable("domain2", html: html)].compactMap { $0 }.first { $0.contains("/ajax") }
        let fallback = (active.passcode.isEmpty ? "/ajaxm.php?file=" : "/ajaxfile.php?file=") + id
        guard let ajax = URL(string: candidate ?? fallback, relativeTo: page.url)?.absoluteURL, LanzouProtocol.safe(ajax), ajax.host?.lowercased() == page.url.host?.lowercased() || ajax.host?.lowercased() == "apifile.woozooo.com" else { throw CloudError.message("蓝奏下载接口地址无效。") }
        var fields = ["action": "downprocess", "sign": sign]
        if !active.passcode.isEmpty { fields["p"] = active.passcode; fields["kd"] = "1" }
        else {
            let key = LanzouProtocol.variable("ajaxdata", html: html) ?? LanzouProtocol.variable("websignkey", html: html) ?? LanzouProtocol.input("websignkey", html: html) ?? ""
            fields.merge(["signs": LanzouProtocol.variable("signs", html: html) ?? key, "websignkey": key, "websign": LanzouProtocol.variable("websign", html: html) ?? "", "kd": LanzouProtocol.first(#"\bkdns\s*=\s*['"]?([0-9]+)"#, in: html) ?? "1", "ves": "1"]) { _, value in value }
        }
        let (data, _) = try await fetch(ajax, form: fields, referer: page.url)
        let result = try json(data)
        guard Self.string(result["zt"]) == "1", let origin = URL(string: Self.string(result["dom"])), LanzouProtocol.safe(origin) else { throw CloudError.message("蓝奏取链失败，请确认提取码和访问限制。") }
        let path = Self.string(result["url"])
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("://"), let jump = URL(string: "/file/" + path, relativeTo: origin)?.absoluteURL else { throw CloudError.message("蓝奏下载节点地址无效。") }
        return try await probe(jump, file: file, referer: page.url)
    }
    private func probe(_ initial: URL, file: CloudFile, referer: URL) async throws -> CloudDownload {
        var current = initial, visited = Set<URL>(), challenged = Set<String>(), confirmed = Set<String>()
        for _ in 0..<8 {
            guard LanzouProtocol.safe(current), visited.insert(current).inserted else { throw CloudError.message("蓝奏下载节点地址无效或循环跳转。") }
            jar[current.host!.lowercased(), default: [:]]["down_ip"] = "1"
            let (_, head) = try await fetch(current, method: "HEAD", referer: referer, allowExternal: true)
            if (300..<400).contains(head.statusCode) {
                guard let location = head.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: current)?.absoluteURL else { throw CloudError.message("蓝奏下载跳转缺少地址。") }; current = next; continue
            }
            guard [200, 206].contains(head.statusCode) else { throw CloudError.message("蓝奏节点拒绝下载或地址已失效。") }
            if Self.isPage(head) {
                let (bytes, _) = try await fetch(current, referer: referer, rangeProbe: true, allowExternal: true)
                let html = String(decoding: bytes, as: UTF8.self)
                if let value = LanzouProtocol.challenge(html), challenged.insert(current.host!.lowercased()).inserted {
                    jar[current.host!.lowercased(), default: [:]]["acw_sc__v2"] = value
                    visited.remove(current); continue
                }
                if html.contains("验证并下载"), confirmed.insert(current.host!.lowercased()).inserted,
                   let file = LanzouProtocol.first(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: html) ?? LanzouProtocol.input("file", html: html),
                   let sign = LanzouProtocol.first(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: html) ?? LanzouProtocol.variable("sign", html: html) ?? LanzouProtocol.input("sign", html: html) {
                    try await Task.sleep(for: .seconds(2))
                    let ajax = URL(string: "ajax.php", relativeTo: current)!.absoluteURL
                    let (raw, _) = try await fetch(ajax, form: ["file": file, "el": "2", "sign": sign], referer: current, allowExternal: true)
                    let result = try json(raw)
                    guard Self.string(result["zt"]) == "1", let next = URL(string: Self.string(result["url"]), relativeTo: current)?.absoluteURL, LanzouProtocol.safe(next), next != current else { throw CloudError.message("蓝奏下载确认失败，请在官网完成验证后重新解析。") }
                    current = next; continue
                }
                throw CloudError.message("蓝奏节点要求进一步验证，请在官网完成后重新解析。")
            }
            var size = Self.contentSize(head)
            if size <= 0 {
                let (bytes, response) = try await fetch(current, referer: referer, rangeProbe: true, allowExternal: true)
                guard [200, 206].contains(response.statusCode), !Self.isPage(response), !String(decoding: bytes.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { throw CloudError.message("蓝奏节点未返回可下载文件。") }
                size = Self.contentSize(response)
            }
            let values = jar[current.host!.lowercased()] ?? [:]
            let cookie = values.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; ")
            return CloudDownload(url: current, filename: file.name, size: size > 0 ? size : file.size, headers: ["User-Agent": LanzouProtocol.agent, "Referer": referer.absoluteString, "Cookie": cookie])
        }
        throw CloudError.message("蓝奏下载节点跳转过多。")
    }
    func mutate(_ operation: CloudMutation) async throws {
        let fields: [String: String]
        switch operation {
        case .createFolder(let name, let parent): try CloudNamePolicy.validate(name); fields = ["task": "2", "parent_id": try root(parent), "folder_name": name, "folder_description": ""]
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            fields = file.isDirectory ? ["task": "4", "folder_id": try LanzouProtocol.rawID(file.id), "folder_name": name, "folder_description": ""] : ["task": "46", "file_id": try LanzouProtocol.rawID(file.id), "file_name": name, "type": "2"]
        case .move(let file, let parent):
            guard !file.isDirectory else { throw CloudError.message("蓝奏接口目前只支持移动文件，不能移动文件夹。") }
            fields = ["task": "20", "folder_id": try root(parent), "file_id": try LanzouProtocol.rawID(file.id)]
        case .trash(let file): fields = ["task": file.isDirectory ? "3" : "6", file.isDirectory ? "folder_id" : "file_id": try LanzouProtocol.rawID(file.id)]
        case .save: throw CloudError.message("蓝奏分享暂不支持直接转存，请下载后自行上传。")
        }
        let result = try await personal(fields)
        if case .createFolder = operation { _ = try LanzouProtocol.rawID(Self.string(result["text"])) }
    }
    private func fetch(_ url: URL, method: String = "GET", form: [String: String]? = nil, account: Bool = false, referer: URL? = nil, rangeProbe: Bool = false, allowExternal: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard LanzouProtocol.safe(url), let host = url.host?.lowercased(), allowExternal || host == "pc.woozooo.com" || host == "apifile.woozooo.com" || LanzouProtocol.shareHost(host), !account || host == "pc.woozooo.com" else { throw CloudError.message("蓝奏请求地址无效。") }
        for attempt in 0..<2 {
            var request = URLRequest(url: url); request.httpMethod = form == nil ? method : "POST"; request.httpBody = form.map(FormEncoding.data)
            request.setValue(LanzouProtocol.agent, forHTTPHeaderField: "User-Agent"); request.setValue((referer ?? url).absoluteString, forHTTPHeaderField: "Referer")
            var origin = URLComponents(url: referer ?? url, resolvingAgainstBaseURL: false)!; origin.path = ""; origin.query = nil; origin.fragment = nil
            request.setValue(origin.url?.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            if form != nil { request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type") }
            if rangeProbe { request.setValue("bytes=0-8191", forHTTPHeaderField: "Range") }
            var values = account ? LanzouProtocol.cookies(cookie) : [:]
            values.merge(jar[host] ?? [:]) { _, value in value }
            if !values.isEmpty { request.setValue(values.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
            do {
                let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw CloudError.message("蓝奏响应无效。") }
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in if let key = item.key as? String { result[key] = String(describing: item.value) } }
                for received in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                    if let expires = received.expiresDate, expires <= Date() { jar[host]?.removeValue(forKey: received.name) } else { jar[host, default: [:]][received.name] = received.value }
                    if account, ["PHPSESSID", "ylogin", "ylogins", "phpdisk_info", "uag", "lanzou_ifo"].contains(received.name) {
                        var accountCookies = LanzouProtocol.cookies(cookie)
                        if let expiry = received.expiresDate, expiry <= Date() { accountCookies.removeValue(forKey: received.name) }
                        else { accountCookies[received.name] = received.value }
                        let merged = accountCookies.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; ")
                        if merged != cookie { cookie = merged; changed?(merged) }
                    }
                }
                var data = Data()
                for try await byte in bytes {
                    if rangeProbe && data.count >= 8192 { break }
                    guard data.count < 2_097_152 else { throw CloudError.message("蓝奏响应超过安全大小。") }; data.append(byte)
                }
                if !rangeProbe, method != "HEAD", let challenge = LanzouProtocol.challenge(String(decoding: data, as: UTF8.self)) {
                    guard attempt == 0 else { throw CloudError.message("蓝奏要求进一步验证，请在官网完成后重新解析。") }
                    jar[host, default: [:]]["acw_sc__v2"] = challenge; continue
                }
                guard http.statusCode != 429 else { throw CloudError.message("蓝奏请求过于频繁，请稍后重试。") }
                if account || form != nil { guard (200..<300).contains(http.statusCode) else { throw CloudError.message("蓝奏操作请求失败，请确认登录或访问限制。") } }
                return (data, http)
            } catch let error as CloudError { throw error }
            catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接蓝奏服务。") }
        }
        throw CloudError.message("蓝奏请求未完成。")
    }
    private func json(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("蓝奏返回验证页面或不支持的数据。") }; return result
    }
    private static func isPage(_ response: HTTPURLResponse) -> Bool { let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""; return ["text/html", "application/json", "text/javascript"].contains { type.contains($0) } }
    private static func contentSize(_ response: HTTPURLResponse) -> Int64 {
        if let range = response.value(forHTTPHeaderField: "Content-Range") { return Int64(range.split(separator: "/").last.map(String.init) ?? "") ?? 0 }
        return response.statusCode == 200 ? Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0 : 0
    }
    private static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }
