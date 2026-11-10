// SPDX-License-Identifier: AGPL-3.0-only
// Protocol port of desktop GuangYaApi.kt. Account and share tokens are separate.
import Foundation

struct GuangYaDevice {
    let id: String
    let sign: String
    init(fields: [String: String] = [:]) {
        let candidate = fields["deviceId"] ?? ""
        id = candidate.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil ? candidate : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let existing = fields["deviceSign"] ?? ""
        sign = existing.hasPrefix("wdi10." + id) && existing.count == 70 ? existing : "wdi10." + id + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    var fields: [String: String] { ["deviceId": id, "deviceSign": sign] }
}

struct GuangYaSMSChallenge {
    let id: String
    let phone: String
    let existing: Bool
    let expires: Date
}

enum CloudMutation {
    case createFolder(name: String, parent: String)
    case rename(file: CloudFile, name: String)
    case move(file: CloudFile, parent: String)
    case trash(file: CloudFile)
    case save(file: CloudFile, share: CloudShare, parent: String)
}

@MainActor
final class GuangYaClient {
    private let session: URLSession
    private var token: String
    private var refreshToken: String
    private let changed: ((String, [String: String]) -> Bool)?
    let device: GuangYaDevice
    private var shareTokens: [String: String] = [:]
    private var cursors: [String: [Int: String]] = [:]
    private var morePages: [String: [Int: Bool]] = [:]
    private var listedCounts: [String: [Int: Int64]] = [:]
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool {
        let parent = parent == "0" ? "" : parent
        let key = (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent
        return morePages[key]?[page] ?? false
    }
    private static let website = "https://www.guangyapan.com"
    private static let clientID = "aMe-8VSlkrbQXpUR"
    private static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    init(token: String = "", fields: [String: String] = [:], session: URLSession, changed: ((String, [String: String]) -> Bool)? = nil) {
        self.token = token.hasPrefix("Bearer ") ? String(token.dropFirst(7)) : token
        self.refreshToken = fields["refreshToken"] ?? ""
        self.changed = changed
        self.device = GuangYaDevice(fields: fields)
        self.session = session
    }
    func login(account: String, password: String) async throws -> (String, [String: String]) {
        var name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 254, !password.isEmpty, password.count <= 256 else { throw CloudError.message("请输入有效的账号和密码。") }
        if name.hasPrefix("+86") { name = "+86 " + String(name.filter(\.isNumber).dropFirst(2)) }
        else if name.count == 11 && name.allSatisfy(\.isNumber) { name = "+86 " + name }
        let metaKey = name.hasPrefix("+") ? "phone_number" : (name.contains("@") ? "email" : "username")
        let captcha = try await request("/v1/shield/captcha/init", body: ["client_id": Self.clientID, "action": "POST:/v1/auth/signin", "device_id": device.id, "captcha_token": "", "meta": [metaKey: name]], account: true)
        guard Self.string(captcha["url"]).isEmpty else { throw CloudError.message("光鸭要求网页安全验证，请在官方页面完成验证后重新登录。") }
        let result = try await request("/v1/auth/signin", body: ["client_id": Self.clientID, "username": name, "password": password], account: true,
                                       extraHeaders: ["X-Captcha-Token": Self.string(captcha["captcha_token"])])
        return try await acceptLogin(result)
    }
    private func acceptLogin(_ result: [String: Any]) async throws -> (String, [String: String]) {
        let data = result["data"] as? [String: Any] ?? result
        let access = Self.first(data, ["access_token", "accessToken"])
        guard !access.isEmpty, !access.contains(where: \.isWhitespace) else { throw CloudError.message("光鸭未返回有效账号令牌。") }
        token = access
        refreshToken = Self.first(data, ["refresh_token", "refreshToken"])
        _ = try await validate()
        var fields = device.fields
        fields["refreshToken"] = refreshToken
        return (token, fields)
    }
    func sendSMS(phone: String) async throws -> GuangYaSMSChallenge {
        let digits = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.range(of: "^1[0-9]{10}$", options: .regularExpression) != nil else { throw CloudError.message("请输入 11 位手机号码。") }
        let normalized = "+86 " + digits
        let captcha = try await request("/v1/shield/captcha/init", body: ["client_id": Self.clientID, "action": "POST:/v1/auth/verification", "device_id": device.id, "captcha_token": "", "meta": ["phone_number": normalized]], account: true)
        guard Self.string(captcha["url"]).isEmpty else { throw CloudError.message("光鸭要求网页安全验证，尚未发送短信。") }
        let root = try await request("/v1/auth/verification", body: ["client_id": Self.clientID, "phone_number": normalized, "target": "ANY"], account: true, extraHeaders: ["X-Captcha-Token": Self.string(captcha["captcha_token"])])
        let data = root["data"] as? [String: Any] ?? root
        let id = Self.string(data["verification_id"])
        guard !id.isEmpty, let existing = data["is_user"] as? Bool else { throw CloudError.message("光鸭未返回有效短信验证信息。") }
        let seconds = max(1, min(1800, Int(Self.string(data["expires_in"])) ?? 600))
        return GuangYaSMSChallenge(id: id, phone: normalized, existing: existing, expires: Date().addingTimeInterval(Double(seconds)))
    }
    func loginSMS(challenge: GuangYaSMSChallenge, code: String, allowRegistration: Bool) async throws -> (String, [String: String]) {
        guard challenge.expires > Date(), code.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else { throw CloudError.message("验证码格式错误或已过期，请重新获取。") }
        guard challenge.existing || allowRegistration else { throw CloudError.message("该手机号尚未注册，请确认同意注册后继续。") }
        let verified = try await request("/v1/auth/verification/verify", body: ["client_id": Self.clientID, "verification_id": challenge.id, "verification_code": code], account: true)
        let data = verified["data"] as? [String: Any] ?? verified
        let verification = Self.string(data["verification_token"])
        guard !verification.isEmpty else { throw CloudError.message("短信验证未返回令牌，请重新获取验证码。") }
        var body: [String: Any] = ["client_id": Self.clientID, "verification_code": code, "verification_token": verification]
        if challenge.existing { body["username"] = challenge.phone }
        else {
            body["phone_number"] = challenge.phone
            let digits = challenge.phone.filter(\.isNumber).dropFirst(2)
            body["name"] = String(digits.prefix(3)) + "****" + String(digits.suffix(4))
        }
        let result = try await request(challenge.existing ? "/v1/auth/signin" : "/v1/auth/signup", body: body, account: true)
        return try await acceptLogin(result)
    }
    func validate() async throws -> String {
        let data = try await request("/v1/user/me", body: nil, account: true, authenticated: true)
        guard !Self.first(data, ["sub", "user_id", "userId"]).isEmpty else { throw CloudError.message("光鸭账号令牌已失效。") }
        let name = Self.first(data, ["nickname", "nick_name", "name", "username"])
        return name.isEmpty ? "光鸭账号" : name
    }
    private func shareToken(_ share: CloudShare) async throws -> String {
        guard share.provider == .guangya else { throw CloudError.message("分享与当前平台不一致。") }
        let key = share.shareID + "|" + share.passcode
        if let cached = shareTokens[key] { return cached }
        let root = try await request("/userres/v1/get_share_access_token", body: ["shareId": share.shareID, "code": share.passcode])
        let value = Self.first(root["data"] as? [String: Any] ?? [:], ["accessToken", "access_token"])
        guard !value.isEmpty else { throw CloudError.message("光鸭未返回分享访问令牌。") }
        shareTokens[key] = value
        return value
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page) else { throw CloudError.message("光鸭分页参数无效。") }
        let parent = parent == "0" ? "" : parent
        let key = (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent
        if page == 1 { morePages[key] = [:]; listedCounts[key] = [:] }
        var body: [String: Any] = ["parentId": parent, "pageSize": 100, "orderBy": 0, "sortType": 0]
        let path: String
        if let share {
            if page == 1 { cursors[key] = [:] }
            else {
                guard let cursor = cursors[key]?[page] else { return [] }
                body["cursor"] = cursor
            }
            body["accessToken"] = try await shareToken(share)
            path = "/userres/v1/get_share_page_files_list"
        } else { body["page"] = page - 1; path = "/userres/v1/file/get_file_list" }
        let root = try await request(path, body: body, authenticated: share == nil)
        guard let data = root["data"] as? [String: Any],
              let records = ["list", "items", "files", "records", "content"].compactMap({ data[$0] as? [[String: Any]] }).first else { throw CloudError.message("光鸭未返回文件列表，已停止翻页。") }
        if share != nil, data["hasMore"] as? Bool == true {
            let next = Self.string(data["cursor"])
            guard !next.isEmpty, next != body["cursor"] as? String else { throw CloudError.message("光鸭分页游标缺失或重复。") }
            cursors[key]?[page + 1] = next
        }
        if share != nil { morePages[key]?[page] = data["hasMore"] as? Bool == true }
        else {
            let count = (listedCounts[key]?[page - 1] ?? 0) + Int64(records.count)
            listedCounts[key]?[page] = count
            let total = Int64(Self.string(data["total"])) ?? 0
            morePages[key]?[page] = data["hasMore"] as? Bool ?? (total > 0 ? count < total : records.count >= 100)
        }
        return try records.map { item in
            let id = Self.first(item, ["fileId", "file_id", "id", "resId", "resourceId"])
            let name = Self.first(item, ["fileName", "name", "filename", "dirName", "title"])
            guard !id.isEmpty, !name.isEmpty else { throw CloudError.message("光鸭文件信息不完整。") }
            let type = Self.string(item["resType"])
            let dir = type == "2" || (type != "1" && (["isDir", "isdir", "dir", "isFolder", "folder"].contains { (item[$0] as? NSNumber)?.boolValue == true } || !Self.string(item["dirName"]).isEmpty || ["folder", "dir", "directory", "0"].contains(Self.first(item, ["type", "fileType"]).lowercased())))
            return CloudFile(id: id, name: name, size: Int64(Self.first(item, ["fileSize", "size", "file_size"])) ?? 0, isDirectory: dir,
                             parentID: Self.first(item, ["parentId", "parentFileId", "parent_id"]), token: "")
        }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory else { throw CloudError.message("请先进入文件夹。") }
        var body: [String: Any] = ["fileId": file.id]
        if let share { body["accessToken"] = try await shareToken(share) }
        let root = try await request(share == nil ? "/userres/v1/get_res_download_url" : "/userres/v1/get_share_download_url", body: body, authenticated: share == nil)
        let data = root["data"] as? [String: Any] ?? [:]
        guard let url = URL(string: Self.first(data, ["signedURL", "signedUrl", "downloadUrl", "download_url", "url", "cdnUrl"])),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { throw CloudError.message("光鸭未返回安全下载地址。") }
        return CloudDownload(url: url, filename: file.name, size: Int64(Self.string(data["size"])) ?? file.size,
                             headers: ["Referer": Self.website + "/", "User-Agent": Self.agent])
    }
    func mutate(_ operation: CloudMutation) async throws {
        let path: String
        let body: [String: Any]
        switch operation {
        case .createFolder(let name, let parent):
            try Self.validateName(name)
            path = "/userres/v1/file/create_dir"
            body = ["parentId": parent == "0" ? "" : parent, "dirName": name, "failIfNameExist": true]
        case .rename(let file, let name):
            try Self.validateName(name)
            path = "/userres/v1/file/rename"; body = ["fileId": file.id, "newName": name]
        case .move(let file, let parent):
            guard file.id != parent else { throw CloudError.message("不能将文件夹移动到自身。") }
            path = "/userres/v1/file/move_file"; body = ["fileIds": [file.id], "parentId": parent == "0" ? "" : parent]
        case .trash(let file):
            path = "/userres/v1/file/delete_file"; body = ["fileIds": [file.id]]
        case .save(let file, let share, let parent):
            let access = try await shareToken(share)
            path = "/userres/v1/restore_share"
            body = ["accessToken": access, "fileIds": [file.id], "parentId": parent == "0" ? "" : parent]
        }
        let root = try await request(path, body: body, authenticated: true)
        let data = root["data"] as? [String: Any] ?? [:]
        if case .createFolder = operation {
            guard !Self.first(data, ["fileId", "id"]).isEmpty, Self.string(data["resType"]) != "1" else { throw CloudError.message("光鸭未确认创建文件夹，请刷新后确认。") }
        }
        let task = Self.string(data["taskId"])
        if !task.isEmpty { try await wait(task) }
    }
    private func wait(_ id: String) async throws {
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(750))
            let root = try await request("/userres/v1/get_task_status", body: ["taskId": id], authenticated: true)
            let data = root["data"] as? [String: Any] ?? [:]
            let status = Self.string(data["status"])
            if status == "2" {
                let detail = data["detail"] as? [String: Any] ?? [:]
                let code = Self.string(detail["code"])
                guard code.isEmpty || code == "0" else { throw CloudError.message("光鸭操作失败，请刷新目录确认。") }
                return
            }
            if status == "3" { throw CloudError.message("光鸭操作失败，请刷新目录确认。") }
        }
        throw CloudError.message("光鸭操作仍在处理中，请稍后刷新确认，避免重复提交。")
    }
    private static func validateName(_ name: String) throws {
        try CloudNamePolicy.validate(name)
    }
    private func request(_ path: String, body: [String: Any]?, account: Bool = false, authenticated: Bool = false, extraHeaders: [String: String] = [:], mayRefresh: Bool = true) async throws -> [String: Any] {
        if authenticated && token.isEmpty { throw CloudError.message("请先登录光鸭账号。") }
        var request = URLRequest(url: URL(string: "https://" + (account ? "account.guangyapan.com" : "api.guangyapan.com") + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var headers = ["Accept": "application/json, text/plain, */*", "User-Agent": Self.agent]
        if account {
            headers.merge(["X-Client-Id": Self.clientID, "X-Client-Version": "0.0.1", "X-Device-Id": device.id, "X-Device-Sign": device.sign,
                           "X-Device-Model": "chrome%2F131.0.0.0", "X-Device-Name": "PC-Chrome", "X-Os-Version": "Win32", "X-Platform-Version": "1", "X-Protocol-Version": "301", "X-Sdk-Version": "9.1.3"]) { _, value in value }
        } else {
            headers.merge(["Origin": Self.website, "Referer": Self.website + "/", "dt": "4", "did": device.id,
                           "traceparent": "00-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() + "-01"]) { _, value in value }
        }
        if authenticated { headers["Authorization"] = "Bearer " + token }
        headers.merge(extraHeaders) { _, value in value }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, http.statusCode == 401, authenticated, mayRefresh, !refreshToken.isEmpty {
            bytes.task.cancel()
            let result = try await self.request("/v1/auth/token", body: ["client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken], account: true, extraHeaders: ["X-Action": "401"], mayRefresh: false)
            let data = result["data"] as? [String: Any] ?? result
            let access = Self.first(data, ["access_token", "accessToken"])
            let replacement = Self.first(data, ["refresh_token", "refreshToken"])
            guard !access.isEmpty, !access.contains(where: \.isWhitespace) else { throw CloudError.message("光鸭登录已失效，请重新登录。") }
            var fields = device.fields
            fields["refreshToken"] = replacement.isEmpty ? refreshToken : replacement
            if let changed, !changed(access, fields) { throw CloudError.message("光鸭刷新后的账号无法保存，请检查钥匙串。") }
            token = access; refreshToken = fields["refreshToken"] ?? ""
            return try await self.request(path, body: body, account: account, authenticated: authenticated, extraHeaders: extraHeaders, mayRefresh: false)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("光鸭请求失败，请检查账号与网络。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw CloudError.message("光鸭响应超出安全大小。") }
            data.append(byte)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("光鸭返回格式无效。") }
        let code = Self.string(root["code"])
        guard root["success"] as? Bool != false, Self.string(root["error"]).isEmpty, code.isEmpty || code == "0" else {
            if code == "209" { throw CloudError.message("光鸭提取码错误或缺失。") }
            if ["200", "201", "202"].contains(code) { throw CloudError.message("光鸭分享已取消或失效。") }
            if ["205", "206", "207", "504"].contains(code) { throw CloudError.message("光鸭分享下载受限，请登录并在官网转存后从个人目录下载。") }
            throw CloudError.message("光鸭拒绝请求，请确认登录状态、下载权限或官方验证要求。")
        }
        return root
    }
    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private static func first(_ data: [String: Any], _ keys: [String]) -> String {
        keys.map { string(data[$0]) }.first { !$0.isEmpty } ?? ""
    }
}
