// SPDX-License-Identifier: AGPL-3.0-only
// Protocol port of desktop BaiduApi.kt; encrypted CDN candidates never masquerade as plain files.
import Foundation

@MainActor
final class BaiduClient {
    private struct Metadata: Codable { let id: String; let path: String }
    private struct ShareSession { let sekey: String; var id = ""; var uk = ""; var rootListed = false }
    private let session: URLSession
    private(set) var cookie: String
    private let changed: ((String) -> Void)?
    private var bdstoken: String?
    private var shares: [String: ShareSession] = [:]
    private var morePages: [String: [Int: Bool]] = [:]
    nonisolated static let webAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    nonisolated static let downloadAgent = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
    init(cookie: String, session: URLSession, changed: ((String) -> Void)? = nil) { self.cookie = cookie; self.session = session; self.changed = changed }
    private func requireAccount() throws {
        guard Self.cookies(cookie)["BDUSS"].map({ !$0.isEmpty }) == true else { throw CloudError.message("请先登录百度网盘。") }
    }
    func validate() async throws -> String {
        try requireAccount()
        let result = try await profile()
        let name = Self.string(result["username"])
        guard !name.isEmpty else { throw CloudError.message("百度账号验证未通过，请完成官网登录。") }
        return name
    }
    private func profile() async throws -> [String: Any] {
        let root = try await request("/api/gettemplatevariable", query: ["fields": #"["username","bdstoken"]"#], readOnly: true)
        guard let result = root["result"] as? [String: Any] else { throw CloudError.message("百度未返回账号参数。") }
        let token = Self.string(result["bdstoken"])
        if !token.isEmpty { bdstoken = token }
        return result
    }
    private func token(force: Bool = false) async throws -> String {
        try requireAccount()
        if force { bdstoken = nil }
        if let bdstoken { return bdstoken }
        _ = try await profile()
        guard let bdstoken, !bdstoken.isEmpty else { throw CloudError.message("百度登录参数已失效，请重新登录。") }
        return bdstoken
    }
    private func shareKey(_ share: CloudShare) -> String { share.shareID + "|" + share.passcode }
    private func pageKey(_ share: CloudShare?, _ parent: String) -> String { (share.map { self.shareKey($0) } ?? "personal") + "|" + parent }
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool { morePages[pageKey(share, Self.folder(parent))]?[page] ?? false }
    private func shareSession(_ share: CloudShare) async throws -> ShareSession {
        guard share.provider == .baidu, share.shareID.hasPrefix("1") else { throw CloudError.message("百度分享地址无效，请使用完整的 /s/1… 链接。") }
        let key = shareKey(share)
        if let cached = shares[key] { return cached }
        var sekey = ""
        if !share.passcode.isEmpty {
            let root = try await request("/share/verify", query: ["surl": String(share.shareID.dropFirst())], form: ["pwd": share.passcode, "vcode_str": "", "vcode": ""], common: false)
            sekey = Self.string(root["randsk"])
            guard sekey.range(of: "^[A-Za-z0-9_+/%=-]{1,4096}$", options: .regularExpression) != nil else { throw CloudError.message("百度未返回有效分享密钥。") }
        }
        let value = ShareSession(sekey: sekey); shares[key] = value
        return value
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page) else { throw CloudError.message("百度分页参数无效。") }
        let parent = try Self.path(Self.folder(parent))
        if let share, parent != "/", shares[shareKey(share)]?.rootListed != true {
            // Account changes can reopen a deep shared directory with a fresh
            // client. Obtain its transfer identifiers before listing children.
            _ = try await list(share: share, parent: "/", page: 1)
        }
        let key = pageKey(share, parent)
        if page == 1 { morePages[key] = [:] }
        let root: [String: Any]
        if let share {
            if page == 1 && parent == "/" { shares.removeValue(forKey: shareKey(share)) }
            let info = try await shareSession(share)
            var query = ["method": "list", "shorturl": String(share.shareID.dropFirst()), "page": String(page), "num": "100", "root": parent == "/" ? "1" : "0", "dir": parent]
            if !info.sekey.isEmpty { query["sekey"] = info.sekey.removingPercentEncoding ?? info.sekey }
            root = try await request("/rest/2.0/xpan/share", query: query, sekey: info.sekey, common: false, readOnly: true)
            var updated = info
            let id = Self.string(root["share_id"]), uk = Self.string(root["uk"])
            if !id.isEmpty { updated.id = id }; if !uk.isEmpty { updated.uk = uk }
            if parent == "/" { updated.rootListed = true }
            shares[shareKey(share)] = updated
        } else {
            root = try await request("/api/list", query: ["channel": "chunlei", "showempty": "0", "order": "time", "desc": "1", "dir": parent, "num": "100", "page": String(page)], needsToken: true, readOnly: true)
        }
        guard let records = root["list"] as? [[String: Any]] else { throw CloudError.message("百度未返回文件列表。") }
        morePages[key]?[page] = (root["has_more"] as? NSNumber)?.boolValue ?? (records.count >= 100)
        return try records.map { item in
            let id = Self.string(item["fs_id"]), name = Self.string(item["server_filename"]), path = Self.string(item["path"])
            let size = Int64(Self.string(item["size"])) ?? 0
            guard !id.isEmpty, !name.isEmpty, size >= 0 else { throw CloudError.message("百度文件信息不完整。") }
            let checked = try Self.path(path)
            let directory = Self.string(item["isdir"]) == "1"
            let metadata = try JSONEncoder().encode(Metadata(id: id, path: checked)).base64EncodedString()
            return CloudFile(id: directory ? checked : id, name: name, size: size, isDirectory: directory, parentID: parent, token: metadata)
        }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard share == nil else { throw CloudError.message("百度分享需先选择目录转存，再从个人网盘下载。") }
        guard !file.isDirectory else { throw CloudError.message("请先进入文件夹。") }
        try requireAccount()
        let metadata = try Self.metadata(file)
        var lastFailure: Error?
        do {
            for url in try await locate(metadata.path) {
                do { return try await probe(url, file: file, agent: Self.downloadAgent) }
                catch { try Self.propagateCancellation(error); lastFailure = error }
            }
        }
        catch { try Self.propagateCancellation(error); lastFailure = error }
        do {
            let root = try await request("/api/filemetas", query: ["dlink": "1", "fsids": try Self.json([metadata.id])], needsToken: true, readOnly: true)
            guard let first = (root["info"] as? [[String: Any]])?.first, let direct = Self.safeURL(Self.string(first["dlink"])) else { throw CloudError.message("百度没有提供可用的明文 HTTPS 下载地址。") }
            // The official Baidu SDK uses this UA for metadata dlinks, rather
            // than the Android UA used by locatedownload.
            return try await probe(direct, file: file, agent: "pan.baidu.com")
        }
        catch {
            try Self.propagateCancellation(error)
            let detail = ((lastFailure as? CloudError)?.localizedDescription ?? "") + ((error as? CloudError)?.localizedDescription ?? "网络请求失败。")
            throw CloudError.message("百度下载地址未通过预检，未创建下载任务。" + detail + " 请重新解析；若持续失败，请在百度官网确认该文件可下载。")
        }
    }
    private static func propagateCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
    }
    private func probe(_ original: URL, file: CloudFile, agent: String) async throws -> CloudDownload {
        var url = original
        let headers = ["User-Agent": agent, "Referer": "https://pan.baidu.com/", "Accept-Encoding": "identity"]
        var visited = Set<URL>()
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { throw CloudError.message("百度下载地址发生循环跳转。") }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            // Use the no-redirect API session and cancel as soon as headers
            // arrive. Never read or retain the complete file during preflight.
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { throw CloudError.message("百度下载响应无效。") }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let target = URL(string: location, relativeTo: url)?.absoluteURL,
                      Self.safeURL(target.absoluteString) != nil else { throw CloudError.message("百度下载跳转不是安全的 HTTPS 地址。") }
                url = target
                continue
            }
            if http.statusCode == 416, file.size == 0, http.value(forHTTPHeaderField: "Content-Range") == "bytes */0" {
                return CloudDownload(url: url, filename: file.name, size: 0, headers: headers, allowsBackground: false)
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw CloudError.message("服务器拒绝下载（HTTP \(http.statusCode)）。")
            }
            if http.statusCode == 206 {
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let parts = range.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "bytes 0-0", let total = Int64(parts[1]),
                      total > 0, file.size == 0 || total == file.size else { throw CloudError.message("百度下载响应的文件范围与平台记录不一致。") }
            } else if file.size > 0, http.expectedContentLength >= 0, http.expectedContentLength != file.size {
                throw CloudError.message("百度下载响应大小与平台记录不一致，可能返回了错误页面。")
            }
            let mime = http.mimeType?.lowercased() ?? ""
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard !(mime == "text/html" && !["html", "htm"].contains(ext)),
                  !(mime == "application/json" && ext != "json") else { throw CloudError.message("百度返回验证页面或错误数据，未返回所选文件。") }
            return CloudDownload(url: url, filename: file.name, size: file.size, headers: headers, allowsBackground: false)
        }
        throw CloudError.message("百度下载跳转次数过多。")
    }
    private func locate(_ path: String) async throws -> [URL] {
        let parameters = ["method": "locatedownload", "path": path, "app_id": "250528", "clienttype": "17", "ver": "4.0", "ant": "1", "check_blue": "1", "es": "1", "esl": "1", "apn_id": "1_-1", "freeisp": "0", "queryfree": "0", "use": "1", "dtype": "1", "eck": "1", "ehps": "1", "err_ver": "1.0", "network_type": "WIFI", "channel": "0", "time": String(Int64(Date().timeIntervalSince1970)),
                          "rand": "5ed606e9da222cde0474cdf70eda884b", "devuid": "0F1E9FC2E084472DA5A61C4CF4C759AF", "cuid": "0F1E9FC2E084472DA5A61C4CF4C759AF", "deviceid": "348642637967375013", "psign": "860a071f77c860e8cea06e4e54c518f3", "version": "2.2.111.34", "version_app": "12.24.6", "vip": "0"]
        let root = try await request("/rest/2.0/pcs/file", host: "d.pcs.baidu.com", query: parameters, body: Data("0".utf8), agent: Self.downloadAgent, common: false, readOnly: true)
        let candidates = (root["urls"] as? [[String: Any]] ?? []).filter { Self.string($0["encrypt"]) == "0" }.sorted { (Int(Self.string($0["rank"])) ?? Int.max) < (Int(Self.string($1["rank"])) ?? Int.max) }
        var seen = Set<URL>()
        let urls = candidates.compactMap({ Self.safeURL(Self.string($0["url"])) }).filter { seen.insert($0).inserted }.prefix(8)
        guard !urls.isEmpty else { throw CloudError.message("百度只返回加密或不安全通道，已停止直接下载。") }
        return Array(urls)
    }
    func mutate(_ operation: CloudMutation) async throws {
        try requireAccount()
        switch operation {
        case .createFolder(let name, let parent):
            try CloudNamePolicy.validate(name)
            let path = try Self.path((Self.folder(parent) == "/" ? "" : Self.folder(parent)) + "/" + name)
            _ = try await request("/api/create", query: ["a": "commit", "channel": "chunlei"], form: ["path": path, "isdir": "1", "size": "", "block_list": "[]", "method": "post", "dataType": "json"], needsToken: true)
        case .save(let file, let share, let parent):
            let metadata = try Self.metadata(file)
            var info = try await shareSession(share)
            if info.id.isEmpty || info.uk.isEmpty { _ = try await list(share: share, parent: "/", page: 1); info = try await shareSession(share) }
            guard !info.id.isEmpty, !info.uk.isEmpty else { throw CloudError.message("百度分享缺少转存标识，请重新解析。") }
            var query = ["shareid": info.id, "from": info.uk, "channel": "chunlei", "ondup": "newcopy"]
            if !info.sekey.isEmpty { query["sekey"] = info.sekey.removingPercentEncoding ?? info.sekey }
            let root = try await request("/share/transfer", query: query, form: ["fsidlist": try Self.json([metadata.id]), "path": try Self.path(Self.folder(parent))], needsToken: true, sekey: info.sekey)
            let result = ((root["extra"] as? [String: Any])?["list"] as? [[String: Any]])?.first
            guard !Self.string(result?["to_fs_id"]).isEmpty else { throw CloudError.message("百度未确认转存结果，请刷新个人目录确认。") }
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            try await manage("rename", entries: [["path": try Self.metadata(file).path, "newname": name]])
        case .move(let file, let parent):
            let metadata = try Self.metadata(file), target = try Self.path(Self.folder(parent))
            guard !file.isDirectory || (target != metadata.path && !target.hasPrefix(metadata.path + "/")) else { throw CloudError.message("不能将目录移动到自身或子目录。") }
            try await manage("move", entries: [["path": metadata.path, "dest": target, "newname": file.name]])
        case .trash(let file): try await manage("delete", entries: [try Self.metadata(file).path])
        }
    }
    private func manage(_ operation: String, entries: Any) async throws {
        let root = try await request("/api/filemanager", query: ["async": "0", "onnest": "fail", "opera": operation, "newVerify": "1"], form: ["filelist": try Self.json(entries)], needsToken: true)
        if let info = root["info"] as? [[String: Any]], info.contains(where: { (Int(Self.string($0["errno"])) ?? 0) != 0 }) { throw CloudError.message("百度文件操作有失败项，请刷新确认。") }
        guard Self.string(root["taskid"]).isEmpty else { throw CloudError.message("百度转为异步处理，请刷新确认结果，避免重复提交。") }
    }
    private static func metadata(_ file: CloudFile) throws -> Metadata {
        guard let raw = Data(base64Encoded: file.token), let metadata = try? JSONDecoder().decode(Metadata.self, from: raw), !metadata.id.isEmpty else { throw CloudError.message("百度文件路径信息缺失，请重新打开目录。") }
        _ = try path(metadata.path)
        return metadata
    }
    private static func folder(_ id: String) -> String { id == "0" || id.isEmpty ? "/" : id }
    private static func path(_ text: String) throws -> String {
        guard text.hasPrefix("/"), text.utf8.count <= 4096, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !text.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw CloudError.message("百度文件路径无效。") }
        return text
    }
    private static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
    private static func cookies(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
    }
    private func request(_ path: String, host: String = "pan.baidu.com", query: [String: String] = [:], form: [String: String]? = nil, body: Data? = nil, needsToken: Bool = false, sekey: String = "", agent: String = BaiduClient.webAgent, common: Bool = true, readOnly: Bool = false) async throws -> [String: Any] {
        guard ["pan.baidu.com", "d.pcs.baidu.com"].contains(host) else { throw CloudError.message("百度请求主机无效。") }
        var values = common ? ["clienttype": "0", "app_id": "250528", "web": "1"] : [:]
        values.merge(query) { _, value in value }
        for attempt in 0..<3 {
            if needsToken { values["bdstoken"] = try await token(force: attempt > 0) }
            var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = path; parts.percentEncodedQuery = FormEncoding.query(values)
            guard let url = parts.url else { throw CloudError.message("百度请求地址无效。") }
            var request = URLRequest(url: url)
            request.httpMethod = form != nil || body != nil ? "POST" : "GET"
            request.httpBody = form.map(FormEncoding.data) ?? body
            var credentials = Self.cookies(cookie)
            if !sekey.isEmpty { credentials["BDCLND"] = sekey }
            if !credentials.isEmpty { request.setValue(credentials.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
            request.setValue(agent, forHTTPHeaderField: "User-Agent"); request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin"); request.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            if request.httpBody != nil { request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type") }
            let root = try await send(request)
            let errno = Int(Self.string(root["errno"]))
            if errno == -6, needsToken, attempt == 0 { continue }
            if errno == -6, needsToken || path == "/api/gettemplatevariable" {
                bdstoken = nil
                throw CloudError.message("百度未接受当前账号的登录状态（错误码 -6）。请重新网页登录并保存账号，再重试个人网盘。")
            }
            if errno == 8888, readOnly, attempt < 2 { try await Task.sleep(for: .seconds(2)); continue }
            guard errno == 0 else { throw CloudError.message("百度拒绝请求（错误码 \(errno ?? -1)），请确认登录、提取码、路径或访问限制。") }
            return root
        }
        throw CloudError.message("百度请求未完成，请稍后重试。")
    }
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("百度网络请求失败或要求网页登录验证。") }
            var data = Data()
            for try await byte in bytes { guard data.count < 2_097_152 else { throw CloudError.message("百度响应超过安全大小。") }; data.append(byte) }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("百度返回了验证页面或不受支持的数据。") }
            if let url = http.url {
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in if let key = item.key as? String { result[key] = String(describing: item.value) } }
                var values = Self.cookies(cookie)
                for received in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) where BaiduCookiePolicy.matchesPanScope(received) {
                    if let expiry = received.expiresDate, expiry <= Date() { values.removeValue(forKey: received.name) } else { values[received.name] = received.value }
                }
                let merged = values.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; ")
                if merged != cookie, !cookie.isEmpty { cookie = merged; changed?(merged) }
            }
            return root
        } catch let error as CloudError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接百度网盘服务。") }
    }
}
