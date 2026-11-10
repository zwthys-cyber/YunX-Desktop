// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor
final class XunleiClient {
    private let session: URLSession
    private(set) var accessToken: String
    private var fields: [String: String]
    private let changed: ((String, [String: String]) -> Bool)?
    private let device: String
    private let credentialDevice: Bool
    private var captcha: String
    private var captchaUntil: TimeInterval
    private var cursors: [String: [Int: String]] = [:]
    private var shareTokens: [String: String] = [:]
    private var web: Bool { (fields["authType"] ?? "").lowercased().hasPrefix("web") }
    var backupFields: [String: String] {
        var value = fields
        value["deviceId"] = device; value["captchaToken"] = captcha; value["captchaExpiresAt"] = String(Int64(captchaUntil * 1000))
        return value
    }
    init(token: String = "", fields: [String: String] = [:], session: URLSession, changed: ((String, [String: String]) -> Bool)? = nil) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        accessToken = token.lowercased().hasPrefix("bearer ") ? String(token.dropFirst(7)) : token
        self.fields = fields; self.session = session; self.changed = changed
        let stored = fields["deviceId"] ?? ""
        credentialDevice = stored.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
        device = credentialDevice ? stored : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        captcha = fields["captchaToken"] ?? ""
        let expiry = Double(fields["captchaExpiresAt"] ?? "") ?? 0
        captchaUntil = expiry.isFinite && expiry > 0 && expiry < 10_000_000_000_000_000 ? expiry / 1000 : (captcha.isEmpty ? 0 : Date().timeIntervalSince1970 + 30)
    }
    func validate() async throws -> String {
        let data = try await call("/drive/v1/about", authenticated: true)
        guard data["kind"] as? String == "drive#about" || data["quota"] is [String: Any] else { throw CloudError.message("迅雷账号未通过网盘接口验证。") }
        return fields["nickname"].flatMap { $0.isEmpty ? nil : $0 } ?? "迅雷账号"
    }
    private func key(_ share: CloudShare?, _ parent: String) -> String {
        (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + (parent == "0" ? "" : parent)
    }
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool { cursors[key(share, parent)]?[page + 1] != nil }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page), share == nil || share?.provider == .xunlei else { throw CloudError.message("迅雷平台或分页参数无效。") }
        let parent = parent == "0" ? "" : parent
        let directoryKey = self.key(share, parent)
        if page == 1 { cursors[directoryKey] = [1: ""] }
        guard let cursor = cursors[directoryKey]?[page] else { return [] }
        let path: String
        var query = [URLQueryItem(name: "page_token", value: cursor), URLQueryItem(name: "limit", value: share == nil ? "50" : "100")]
        if let share {
            query.append(URLQueryItem(name: "share_id", value: share.shareID))
            query.append(URLQueryItem(name: "thumbnail_size", value: "SIZE_SMALL"))
            if parent.isEmpty {
                path = "/drive/v1/share"; query.append(URLQueryItem(name: "pass_code", value: share.passcode))
            } else {
                if shareTokens[self.key(share, "")] == nil { _ = try await list(share: share, parent: "", page: 1) }
                path = "/drive/v1/share/detail"
                query += [URLQueryItem(name: "parent_id", value: parent), URLQueryItem(name: "pass_code_token", value: shareTokens[self.key(share, "")] ?? "")]
            }
        } else {
            path = "/drive/v1/files"
            query += [URLQueryItem(name: "parent_id", value: parent), URLQueryItem(name: "with_audit", value: "true"), URLQueryItem(name: "filters", value: #"{"trashed":{"eq":false}}"#)]
        }
        let data = try await call(path, query: query, authenticated: share == nil || !accessToken.isEmpty)
        if let share, parent.isEmpty {
            guard !["PASS_CODE_EMPTY", "PASS_CODE_ERROR", "PASS_CODE_NEED"].contains(XunleiProtocol.string(data["share_status"])) else { throw CloudError.message("迅雷分享需要正确的提取码。") }
            shareTokens[self.key(share, "")] = XunleiProtocol.string(data["pass_code_token"])
        }
        guard let records = data["files"] as? [[String: Any]] else { throw CloudError.message("迅雷未返回文件列表。") }
        cursors[directoryKey]?[page + 1] = nil
        let next = XunleiProtocol.string(data["next_page_token"])
        if !next.isEmpty {
            guard next != cursor else { throw CloudError.message("迅雷分页游标重复。") }
            cursors[directoryKey]?[page + 1] = next
        }
        return try records.map { item in
            let id = XunleiProtocol.string(item["id"]), name = XunleiProtocol.string(item["name"])
            let size = Int64(XunleiProtocol.string(item["size"])) ?? 0
            guard !id.isEmpty, !name.isEmpty, size >= 0 else { throw CloudError.message("迅雷文件条目信息不完整。") }
            return CloudFile(id: id, name: name, size: size, isDirectory: item["kind"] as? String == "drive#folder", parentID: XunleiProtocol.string(item["parent_id"]), token: "")
        }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard share == nil else { throw CloudError.message("迅雷分享需先转存；请长按文件选择目标目录，再从个人网盘下载。") }
        guard !file.isDirectory else { throw CloudError.message("请先进入文件夹。") }
        let id = try Self.identifier(file.id)
        let data = try await call("/drive/v1/files/" + id, query: [URLQueryItem(name: "_magic", value: "2021"), URLQueryItem(name: "usage", value: "PLAY"), URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"), URLQueryItem(name: "with", value: "hdr10"), URLQueryItem(name: "with", value: "subtitle_files"), URLQueryItem(name: "with", value: "task"), URLQueryItem(name: "with", value: "public_share_tag")], authenticated: true)
        let links = data["links"] as? [String: Any]
        let raw = XunleiProtocol.string((links?["application/octet-stream"] as? [String: Any])?["url"])
        let fallback = XunleiProtocol.string(data["web_content_link"])
        guard let url = URL(string: raw.isEmpty ? fallback : raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { throw CloudError.message("迅雷未返回安全下载直链，请确认账号和文件权限。") }
        let name = XunleiProtocol.string(data["name"])
        return CloudDownload(url: url, filename: name.isEmpty ? file.name : name, size: Int64(XunleiProtocol.string(data["size"])) ?? file.size, headers: ["User-Agent": XunleiProtocol.webAgent, "Referer": "https://pan.xunlei.com/"])
    }
    func mutate(_ operation: CloudMutation) async throws {
        let path: String, method: String
        let body: [String: Any]
        switch operation {
        case .createFolder(let name, let parent):
            try CloudNamePolicy.validate(name)
            path = "/drive/v1/files"; method = "POST"
            body = ["kind": "drive#folder", "name": name, "parent_id": parent == "0" ? "" : parent, "space": ""]
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            path = "/drive/v1/files/" + (try Self.identifier(file.id)); method = "PATCH"; body = ["name": name]
        case .move(let file, let parent):
            guard file.id != parent else { throw CloudError.message("不能将文件夹移动到自身。") }
            path = "/drive/v1/files:batchMove"; method = "POST"
            body = ["ids": [file.id], "to": ["parent_id": parent == "0" ? "" : parent, "space": ""], "space": ""]
        case .trash(let file):
            path = "/drive/v1/files:batchTrash"; method = "POST"; body = ["ids": [file.id], "space": ""]
        case .save(let file, let share, let parent):
            guard share.provider == .xunlei else { throw CloudError.message("分享与当前平台不一致。") }
            if shareTokens[key(share, "")] == nil { _ = try await list(share: share, parent: "", page: 1) }
            path = "/drive/v1/share/restore"; method = "POST"
            body = ["share_id": share.shareID, "pass_code_token": shareTokens[key(share, "")] ?? "", "parent_id": parent == "0" ? "" : parent, "ancestor_ids": [String](), "file_ids": [file.id], "specify_parent_id": true]
        }
        let data = try await call(path, method: method, body: body, authenticated: true)
        if case .createFolder = operation {
            guard !XunleiProtocol.string(data["id"]).isEmpty else { throw CloudError.message("迅雷未确认创建目录，请刷新确认。") }
        }
        if case .rename = operation {
            guard !XunleiProtocol.string(data["id"]).isEmpty else { throw CloudError.message("迅雷未确认重命名，请刷新确认。") }
        }
        let task = XunleiProtocol.string(data["task_id"])
        if !task.isEmpty { try await wait(task) }
        else if case .save(let file, _, _) = operation {
            let params = data["params"] as? [String: Any] ?? [:]
            let trace = XunleiProtocol.string(params["trace_file_ids"])
            let mapping = trace.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard !XunleiProtocol.string(mapping?[file.id]).isEmpty || !XunleiProtocol.string(data["file_id"]).isEmpty else { throw CloudError.message("迅雷尚未明确返回转存结果，请刷新个人目录确认。") }
        }
    }
    private func wait(_ id: String) async throws {
        let id = try Self.identifier(id)
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            let data = try await call("/drive/v1/tasks/" + id, query: [URLQueryItem(name: "type", value: "share")], authenticated: true)
            let phase = XunleiProtocol.string(data["phase"]), status = XunleiProtocol.string(data["status"])
            if [phase, status].contains("PHASE_TYPE_COMPLETE") { return }
            if [phase, status].contains("PHASE_TYPE_ERROR") || [phase, status].contains("PHASE_TYPE_FAILED") || (Int(XunleiProtocol.string(data["error_code"])) ?? 0) != 0 { throw CloudError.message("迅雷文件操作失败，请刷新确认。") }
        }
        throw CloudError.message("迅雷仍在处理操作，请刷新确认，避免重复提交。")
    }
    private static func identifier(_ id: String) throws -> String {
        guard id.range(of: "^[A-Za-z0-9_=-]{1,256}$", options: .regularExpression) != nil else { throw CloudError.message("迅雷文件标识无效。") }
        return id
    }
    private func call(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, authenticated: Bool) async throws -> [String: Any] {
        if authenticated {
            guard XunleiProtocol.validToken(accessToken), credentialDevice else { throw CloudError.message("请使用迅雷官网登录并保存包含设备标识的凭据。") }
        }
        for attempt in 0..<2 {
            if authenticated { try await ensureCaptcha(action: method + ":" + path, force: false) }
            var request = try self.request(host: "api-pan.xunlei.com", path: path, method: method, query: query, body: body)
            request.setValue(XunleiProtocol.appVersion, forHTTPHeaderField: "X-Client-Version")
            if authenticated {
                request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
                if !captcha.isEmpty { request.setValue(captcha, forHTTPHeaderField: "X-Captcha-Token") }
            }
            let (status, root) = try await send(request)
            let error = XunleiProtocol.string(root["error"])
            if authenticated, attempt == 0, status == 401 || error == "unauthenticated" {
                try await refreshAccess()
                try await ensureCaptcha(action: method + ":" + path, force: true)
                continue
            }
            if authenticated, attempt == 0, error == "captcha_invalid" {
                try await ensureCaptcha(action: method + ":" + path, force: true)
                continue
            }
            guard (200..<300).contains(status), error.isEmpty else { throw CloudError.message("迅雷拒绝请求，请确认登录、提取码、访问权限或在官方页面完成验证。") }
            return root["data"] as? [String: Any] ?? root
        }
        throw CloudError.message("迅雷验证刷新后仍未通过，请重新登录官网。")
    }
    private func ensureCaptcha(action: String, force: Bool) async throws {
        if !force, !captcha.isEmpty, captchaUntil > Date().timeIntervalSince1970 { return }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var meta: [String: Any] = ["client_version": web ? XunleiProtocol.webVersion : XunleiProtocol.appVersion, "package_name": web ? "pan.xunlei.com" : "com.xunlei.downloadprovider", "timestamp": timestamp,
                                 "captcha_sign": XunleiProtocol.captchaSign(device: device, timestamp: timestamp, web: web), "user_id": fields["userId"].flatMap { $0.isEmpty ? nil : $0 } ?? XunleiProtocol.subject(accessToken)]
        if web { meta.merge(["username": "", "phone_number": "", "email": ""]) { _, value in value } }
        var body: [String: Any] = ["client_id": web ? XunleiProtocol.webID : XunleiProtocol.appID, "action": action, "device_id": device, "meta": meta]
        if !web { body["redirect_uri"] = "xlaccsdk01://xunlei.com/callback?state=harbor"; body["captcha_token"] = captcha }
        var request = try self.request(host: "xluser-ssl.xunlei.com", path: "/v1/shield/captcha/init", method: "POST", body: body)
        request.setValue(web ? "text/plain;charset=UTF-8" : "application/json", forHTTPHeaderField: "Content-Type")
        if !web {
            request.setValue(XunleiProtocol.appAgent, forHTTPHeaderField: "User-Agent"); request.setValue(XunleiProtocol.appID, forHTTPHeaderField: "X-Client-Id")
            request.setValue(XunleiProtocol.appVersion, forHTTPHeaderField: "X-Client-Version")
            for key in ["Sec-Ch-Ua", "Sec-Ch-Ua-Mobile", "Sec-Ch-Ua-Platform"] { request.setValue(nil, forHTTPHeaderField: key) }
        }
        let (status, root) = try await send(request)
        let value = XunleiProtocol.string(root["captcha_token"])
        guard (200..<300).contains(status), XunleiProtocol.validToken(value), XunleiProtocol.string(root["url"]).isEmpty else { throw CloudError.message("迅雷需要更新网页验证，请重新进入官方登录页；签名参数可能随平台版本变化。") }
        captcha = value; captchaUntil = Date().timeIntervalSince1970 + 270
        try persist()
    }
    private func refreshAccess() async throws {
        guard let refresh = fields["refreshToken"], !refresh.isEmpty else { throw CloudError.message("迅雷登录已过期，请重新登录。") }
        var request = try self.request(host: "xluser-ssl.xunlei.com", path: "/v1/auth/token", method: "POST", body: web ? ["grant_type": "refresh_token", "client_id": XunleiProtocol.webID, "refresh_token": refresh] : nil)
        request.setValue(web ? XunleiProtocol.webID : XunleiProtocol.appID, forHTTPHeaderField: "X-Client-Id")
        if !web {
            request.setValue(XunleiProtocol.appAgent, forHTTPHeaderField: "User-Agent")
            for key in ["Sec-Ch-Ua", "Sec-Ch-Ua-Mobile", "Sec-Ch-Ua-Platform"] { request.setValue(nil, forHTTPHeaderField: key) }
            request.httpBody = FormEncoding.data(["grant_type": "refresh_token", "client_id": XunleiProtocol.appID, "client_secret": XunleiProtocol.appSecret, "refresh_token": refresh])
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (status, root) = try await send(request)
        let new = XunleiProtocol.string(root["access_token"])
        guard (200..<300).contains(status), XunleiProtocol.validToken(new) else { throw CloudError.message("迅雷令牌刷新失败，请重新登录。") }
        let oldSubject = XunleiProtocol.subject(accessToken), newSubject = XunleiProtocol.subject(new)
        guard oldSubject.isEmpty || newSubject.isEmpty || oldSubject == newSubject else { throw CloudError.message("迅雷刷新结果与所选账号不一致，已停止保存。") }
        accessToken = new
        let rotated = XunleiProtocol.string(root["refresh_token"])
        guard rotated.isEmpty || XunleiProtocol.validToken(rotated) else { throw CloudError.message("迅雷返回的刷新令牌格式无效，已停止保存。") }
        if !rotated.isEmpty { fields["refreshToken"] = rotated }
        if !newSubject.isEmpty { fields["userId"] = newSubject }
        try persist()
    }
    private func persist() throws {
        if let changed, !changed(accessToken, backupFields) { throw CloudError.message("迅雷新凭据无法保存，请检查钥匙串。") }
    }
    private func request(host: String, path: String, method: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CloudError.message("迅雷请求地址无效。") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue(XunleiProtocol.webAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(device, forHTTPHeaderField: "X-Device-Id")
        request.setValue("https://pan.xunlei.com", forHTTPHeaderField: "Origin"); request.setValue("https://pan.xunlei.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"", forHTTPHeaderField: "Sec-Ch-Ua")
        request.setValue("?0", forHTTPHeaderField: "Sec-Ch-Ua-Mobile"); request.setValue("\"Windows\"", forHTTPHeaderField: "Sec-Ch-Ua-Platform")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func send(_ request: URLRequest) async throws -> (Int, [String: Any]) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw CloudError.message("迅雷响应无效。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_097_152 else { throw CloudError.message("迅雷响应超过安全大小。") }
                data.append(byte)
            }
            if data.isEmpty { return (http.statusCode, [:]) }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("迅雷返回了验证页面或不受支持的数据。") }
            return (http.statusCode, root)
        } catch let error as CloudError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接迅雷服务，请检查网络。") }
    }
}
