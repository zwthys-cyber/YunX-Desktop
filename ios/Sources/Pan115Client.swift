// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor
final class Pan115Client {
    private struct Reply { let json: [String: Any]; let cookies: [HTTPCookie] }
    private let session: URLSession
    private let cookie: String
    private var more: [String: [Int: Bool]] = [:]
    private var offsets: [String: [Int: Int]] = [:]
    private var owners: [String: String] = [:]
    private var fetchedVersion = false
    private var clientAgent = "Mozilla/5.0 115Browser/36.0.1"
    nonisolated static let webAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    init(cookie: String, session: URLSession) { self.cookie = cookie; self.session = session }
    private func key(_ share: CloudShare?, _ parent: String) -> String { (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent }
    private func root(_ parent: String) -> String { parent.isEmpty ? "0" : parent }
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool { more[key(share, root(parent))]?[page] ?? false }
    private func requireAccount() throws {
        let values = Self.cookies(cookie)
        guard ["UID", "CID", "SEID"].allSatisfy({ values[$0]?.isEmpty == false }) else { throw CloudError.message("请先登录 115，Cookie 需包含 UID、CID 和 SEID。") }
    }
    func validate() async throws -> String {
        try requireAccount()
        let root = try await request("/user/info", query: ["ct": "json"]).json
        try Self.check(root)
        guard let name = root["data"] as? String, !name.isEmpty else { throw CloudError.message("115 未返回有效账号信息。") }
        return name
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page), share == nil || share?.provider == .pan115 else { throw CloudError.message("115 平台或分页参数无效。") }
        if share == nil { try requireAccount() }
        let parent = root(parent), key = key(share, root(parent))
        if page == 1 { more[key] = [:]; offsets[key] = [1: 0] }
        guard let offset = offsets[key]?[page] else { throw CloudError.message("115 分页位置已失效，请重新打开目录。") }
        var query = ["cid": parent, "offset": String(offset), "limit": "100", "asc": "0", "format": "json"]
        let path: String
        if let share { path = "/share/snap"; query["share_code"] = share.shareID; query["receive_code"] = share.passcode }
        else { path = "/files"; query.merge(["aid": "1", "o": "user_ptime", "show_dir": "1", "snap": "0", "natsort": "1", "record_open_time": "1", "count_folders": "1"]) { _, v in v } }
        let result = try await request(path, query: query, referer: share.map(Self.referer)).json
        try Self.check(result)
        let rows: [[String: Any]], total: Int?
        if let share {
            guard let data = result["data"] as? [String: Any], let list = data["list"] as? [[String: Any]] else { throw CloudError.message("115 未返回分享文件列表。") }
            rows = list; total = Int(Self.string(data["count"]))
            let owner = Self.string((data["userinfo"] as? [String: Any])?["user_id"])
            if !owner.isEmpty { owners[share.shareID + "|" + share.passcode] = owner }
        } else {
            guard let list = result["data"] as? [[String: Any]] else { throw CloudError.message("115 未返回个人文件列表。") }
            rows = list; total = Int(Self.string(result["count"]))
        }
        more[key]?[page] = total.map { offset + rows.count < $0 } ?? (rows.count >= 100)
        offsets[key]?.removeValue(forKey: page + 1)
        if more[key]?[page] == true { offsets[key]?[page + 1] = offset + rows.count }
        return try rows.map { item in
            let fid = Self.string(item["fid"])
            let directory = share == nil ? fid.isEmpty : (Int(Self.string(item["fc"])) ?? (fid.isEmpty ? 0 : 1)) == 0
            let id = directory ? Self.string(item["cid"]) : fid, name = Self.string(item["n"])
            let size = directory ? 0 : (Int64(Self.string(item["s"])) ?? 0)
            guard !id.isEmpty, !name.isEmpty, size >= 0 else { throw CloudError.message("115 文件信息不完整。") }
            return CloudFile(id: id, name: name, size: size, isDirectory: directory, parentID: parent, token: Self.string(item["pc"]))
        }
    }
    private func refreshVersion() async throws {
        guard !fetchedVersion else { return }; fetchedVersion = true
        do {
            let result = try await request("/1/web/1.0/api/chrome", host: "appversion.115.com", credentials: false).json
            let version = Self.string(((result["data"] as? [String: Any])?["win"] as? [String: Any])?["version_code"])
            if version.range(of: "^[0-9]+(?:\\.[0-9]+){1,4}$", options: .regularExpression) != nil, version.count <= 16 { clientAgent = "Mozilla/5.0 115Browser/" + version }
        } catch { if Task.isCancelled { throw CancellationError() } }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory else { throw CloudError.message("请进入文件夹后选择文件。") }
        try await refreshVersion()
        let reply: Reply, data: [String: Any]
        if let share {
            guard share.provider == .pan115 else { throw CloudError.message("115 分享平台不一致。") }
            let key = share.shareID + "|" + share.passcode
            if owners[key] == nil { _ = try await list(share: share, parent: "0", page: 1) }
            guard let owner = owners[key], !owner.isEmpty else { throw CloudError.message("115 缺少分享者标识，请重新解析。") }
            reply = try await request("/share/downurl", query: ["dl": "1", "user_id": owner, "share_code": share.shareID, "file_id": file.id, "receive_code": share.passcode], referer: Self.referer(share), agent: clientAgent)
            try Self.check(reply.json)
            guard let value = reply.json["data"] as? [String: Any] else { throw CloudError.message("115 未返回分享下载信息。") }; data = value
        } else {
            try requireAccount()
            guard !file.token.isEmpty else { throw CloudError.message("115 缺少 pickcode，请重新打开目录。") }
            do {
                let key = try Pan115Crypto.newKey()
                let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["pickcode": file.token], options: [.sortedKeys]), as: UTF8.self)
                let result = try await request("/app/chrome/downurl", host: "proapi.115.com", query: ["t": String(Int64(Date().timeIntervalSince1970))], form: ["data": try Pan115Crypto.encode(payload, key: key)], agent: clientAgent)
                try Self.check(result.json)
                let decoded = try Pan115Crypto.decode(Self.string(result.json["data"]), key: key)
                guard let root = try JSONSerialization.jsonObject(with: decoded) as? [String: Any], let info = root[file.id] as? [String: Any] else { throw CloudError.message("115 下载响应未匹配原文件，请刷新后重试。") }
                return try plan(info, file: file, cookies: result.cookies)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                reply = try await request("/files/download", query: ["pickcode": file.token], agent: clientAgent)
                try Self.check(reply.json)
                guard let value = reply.json["data"] as? [String: Any] else { throw CloudError.message("115 未返回可用下载信息。") }; data = value
            }
        }
        return try plan(data, file: file, cookies: reply.cookies)
    }
    private func plan(_ data: [String: Any], file: CloudFile, cookies: [HTTPCookie]) throws -> CloudDownload {
        let nested = (data["url"] as? [String: Any])?["url"]
        let raw = [Self.string(data["file_url_302"]), Self.string(data["file_url"]), Self.string(nested)].first { !$0.isEmpty } ?? ""
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { throw CloudError.message("115 未返回有效 HTTPS 下载地址。") }
        var headers = ["User-Agent": clientAgent, "Referer": "https://115.com/"]
        var values: [String: String] = [:]
        // Account cookies stay within the provider family. Download-only cookies are
        // bound to the exact returned origin by DownloadStore's redirect policy.
        if ["115.com", "115cdn.com", "anxia.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { values = Self.cookies(cookie) }
        for cookie in cookies where cookie.path != "/" && (url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")) && (cookie.expiresDate == nil || cookie.expiresDate! > Date()) { values[cookie.name] = cookie.value }
        if !values.isEmpty { headers["Cookie"] = values.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; ") }
        let name = [Self.string(data["file_name"]), Self.string(data["fn"])].first { !$0.isEmpty } ?? file.name
        let size = Int64(Self.string(data["file_size"])) ?? Int64(Self.string(data["fs"])) ?? file.size
        guard size >= 0 else { throw CloudError.message("115 下载大小无效。") }
        return CloudDownload(url: url, filename: name, size: size, headers: headers)
    }
    func mutate(_ operation: CloudMutation) async throws {
        try requireAccount()
        let path: String, form: [String: String]
        switch operation {
        case .createFolder(let name, let parent): try CloudNamePolicy.validate(name); path = "/files/add"; form = ["pid": root(parent), "cname": name]
        case .rename(let file, let name): try CloudNamePolicy.validate(name); path = "/files/batch_rename"; form = ["fid": file.id, "file_name": name, "files_new_name[\(file.id)]": name]
        case .move(let file, let parent):
            guard file.id != parent else { throw CloudError.message("不能将目录移动到自身。") }; path = "/files/move"; form = ["pid": root(parent), "fid[0]": file.id]
        case .trash(let file): path = "/rb/delete"; form = ["pid": root(file.parentID), "fid[0]": file.id, "ignore_warn": "1"]
        case .save(let file, let share, let parent):
            guard share.provider == .pan115 else { throw CloudError.message("115 分享平台不一致。") }; path = "/share/receive"; form = ["share_code": share.shareID, "receive_code": share.passcode, "file_id": file.id, "cid": root(parent)]
        }
        let result = try await request(path, form: form).json
        try Self.check(result)
        if case .createFolder = operation {
            guard !Self.string(result["cid"]).isEmpty || !Self.string((result["data"] as? [String: Any])?["cid"]).isEmpty else { throw CloudError.message("115 未确认新建目录。") }
        }
        let task = Self.string(result["move_proid"]).isEmpty ? Self.string((result["data"] as? [String: Any])?["move_proid"]) : Self.string(result["move_proid"])
        if !task.isEmpty {
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                let root = try await request("/files/move_progress", query: ["move_proid": task]).json
                try Self.check(root)
                guard let data = root["data"] as? [String: Any] else { throw CloudError.message("115 任务响应缺少数据，请刷新确认。") }
                if (Double(Self.string(data["percent"])) ?? 0) >= 100 { return }
            }
            throw CloudError.message("115 操作仍在处理中，请刷新确认，避免重复提交。")
        }
    }
    private static func referer(_ share: CloudShare) -> String {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "115cdn.com"; parts.path = "/s/" + share.shareID
        if !share.passcode.isEmpty { parts.queryItems = [URLQueryItem(name: "password", value: share.passcode)] }
        return parts.url?.absoluteString ?? "https://115.com/"
    }
    private func request(_ path: String, host: String = "webapi.115.com", query: [String: String] = [:], form: [String: String]? = nil, referer: String? = nil, agent: String = Pan115Client.webAgent, credentials: Bool = true) async throws -> Reply {
        guard ["webapi.115.com", "proapi.115.com", "appversion.115.com"].contains(host) else { throw CloudError.message("115 请求主机无效。") }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = path
        if !query.isEmpty { parts.percentEncodedQuery = FormEncoding.query(query) }
        guard let url = parts.url else { throw CloudError.message("115 请求地址无效。") }
        var request = URLRequest(url: url); request.httpMethod = form == nil ? "GET" : "POST"; request.httpBody = form.map(FormEncoding.data)
        request.setValue(agent, forHTTPHeaderField: "User-Agent"); request.setValue(referer ?? "https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept"); request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if credentials, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if form != nil { request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("115 网络请求失败或要求重新登录。") }
            var data = Data()
            for try await byte in bytes { guard data.count < 2_097_152 else { throw CloudError.message("115 响应超过安全大小。") }; data.append(byte) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("115 返回验证页面或不支持的数据。") }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in if let key = item.key as? String { result[key] = String(describing: item.value) } }
            return Reply(json: json, cookies: HTTPCookie.cookies(withResponseHeaderFields: headers, for: url))
        } catch let error as CloudError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接 115 网盘。") }
    }
    private static func cookies(_ text: String) -> [String: String] {
        text.split(separator: ";").reduce(into: [:]) { result, pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
    }
    private static func check(_ root: [String: Any]) throws {
        guard root["state"] as? Bool == true else {
            let code = Int(string(root["errno"])) ?? Int(string(root["errNo"])) ?? -1
            throw CloudError.message("115 拒绝请求（错误码 \(code)），请确认登录、访问码、版本或文件权限。")
        }
    }
    private static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
}
