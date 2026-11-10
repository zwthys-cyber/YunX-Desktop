// SPDX-License-Identifier: AGPL-3.0-only
// Protocol port of desktop ILanzouApi.kt. The fixed AES key is a public API parameter.
import Foundation
import CommonCrypto

enum ILanzouProtocol {
    static func aesHex(_ text: String) throws -> String {
        let key = Array("lanZouY-disk-app".utf8)
        let input = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = key.withUnsafeBytes { key in
            input.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key.baseAddress, key.count, nil,
                        input.baseAddress, input.count, &output, capacity, &count)
            }
        }
        guard status == kCCSuccess else { throw CloudError.message("蓝奏优享请求参数生成失败。") }
        return output.prefix(count).map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ text: String) -> String {
        FormEncoding.encode(text, literalColon: true)
    }
    static func rawID(_ id: String) throws -> String {
        let value = id.hasPrefix("d:") || id.hasPrefix("f:") ? String(id.dropFirst(2)) : id
        guard value.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw CloudError.message("蓝奏优享文件标识无效。") }
        return value
    }
}

@MainActor
final class ILanzouClient {
    private let session: URLSession
    private var token: String
    private var uuid: String
    private var userID: String
    private var finalPages: [String: Int] = [:]
    func hasMore(share: CloudShare?, parent: String, page: Int, count: Int) -> Bool {
        guard let parent = try? ILanzouProtocol.rawID(parent) else { return false }
        let key = (share?.shareID ?? "personal") + "|" + parent
        if let last = finalPages[key] { return page < last }
        return count >= 60
    }
    private static let site = "https://www.ilanzou.com"
    private static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    init(token: String = "", fields: [String: String] = [:], session: URLSession) {
        self.token = token
        let stored = fields["uuid"] ?? ""
        uuid = stored.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil ? stored : ""
        userID = fields["userId"] ?? ""
        self.session = session
    }
    private func ensureUUID() async throws {
        if !uuid.isEmpty { return }
        let root = try await request("/unproved/getUuid").json
        let value = Self.string(root["uuid"])
        guard value.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil else { throw CloudError.message("蓝奏优享未返回有效设备标识。") }
        uuid = value
    }
    func login(account: String, password: String) async throws -> (String, [String: String]) {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 254, !password.isEmpty, password.count <= 256 else { throw CloudError.message("请输入有效的蓝奏优享账号和密码。") }
        try await ensureUUID()
        let root = try await request("/unproved/login", body: ["loginName": name, "loginPwd": password]).json
        let value = Self.string((root["data"] as? [String: Any])?["appToken"])
        guard value.count >= 16, value.range(of: #"^[A-Za-z0-9._~+/=:!%&?\-]+$"#, options: .regularExpression) != nil else { throw CloudError.message("蓝奏优享未返回有效账号令牌。") }
        token = value
        _ = try await validate()
        return (token, ["uuid": uuid, "userId": userID])
    }
    func validate() async throws -> String {
        try await ensureUUID()
        let root = try await request("/proved/user/account/map", authenticated: true).json
        let map = root["map"] as? [String: Any] ?? [:]
        userID = Self.string(map["userId"])
        guard !userID.isEmpty, userID != "0" else { throw CloudError.message("蓝奏优享账号状态无效。") }
        return ["nickName", "nickname", "account"].map { Self.string(map[$0]) }.first { !$0.isEmpty } ?? "蓝奏优享账号"
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page) else { throw CloudError.message("蓝奏优享分页无效。") }
        if let share { try checkShare(share) }
        try await ensureUUID()
        let parent = try ILanzouProtocol.rawID(parent)
        let key = (share?.shareID ?? "personal") + "|" + parent
        if page == 1 { finalPages.removeValue(forKey: key) }
        if let last = finalPages[key], page > last { return [] }
        var parameters = ["offset": String(page), "limit": "60"]
        if share == nil || parent != "0" { parameters["folderId"] = parent }
        if share == nil { parameters["type"] = "0" }
        let root = try await request(share == nil ? "/proved/record/file/list" : "/unproved/share/list", share: share, authenticated: share == nil, parameters: parameters).json
        guard let items = root["list"] as? [[String: Any]] else { throw CloudError.message("蓝奏优享未返回文件列表。") }
        let totalPage = Int(Self.string(root["totalPage"])) ?? 0
        if totalPage > 0 { finalPages[key] = totalPage }
        else if items.count < 60 { finalPages[key] = page }
        return try items.map { item in
            let directory = Self.string(item["fileType"]) == "2"
            let id = Self.string(item[directory ? "folderId" : "fileId"])
            let name = Self.string(item[directory ? "folderName" : "fileName"])
            _ = try ILanzouProtocol.rawID(id)
            guard id != "0", !name.isEmpty else { throw CloudError.message("蓝奏优享条目信息不完整。") }
            let size = Int64(Self.string(item["fileSize"])) ?? 0
            let (bytes, overflow) = max(0, size).multipliedReportingOverflow(by: 1024)
            guard !overflow else { throw CloudError.message("蓝奏优享文件大小无效。") }
            return CloudFile(id: (directory ? "d:" : "f:") + id, name: name, size: directory ? 0 : bytes, isDirectory: directory, parentID: parent, token: "")
        }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory else { throw CloudError.message("请进入文件夹后下载文件。") }
        if let share { try checkShare(share) }
        try await ensureUUID()
        if !token.isEmpty && userID.isEmpty { _ = try await validate() }
        let id = try ILanzouProtocol.rawID(file.id)
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let stamp = try ILanzouProtocol.aesHex(timestamp)
        let parameters = ["enable": "1", "downloadId": try ILanzouProtocol.aesHex(id + "|" + (token.isEmpty ? "" : userID)), "auth": try ILanzouProtocol.aesHex(id + "|" + timestamp)]
        let result = try await request("/unproved/file/redirect", share: share, authenticated: share == nil, parameters: parameters, extra: false, timestamp: stamp, allowLocation: true)
        let raw = result.location ?? Self.string(result.json["url"])
        let nested = Self.string((result.json["data"] as? [String: Any])?["url"])
        guard let url = URL(string: raw.isEmpty ? nested : raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              !["apis.ilanzou.com", "apix.ilanzou.com"].contains(url.host?.lowercased() ?? "") else { throw CloudError.message("蓝奏优享未返回安全的文件下载直链。") }
        // Listed sizes are rounded KiB, not exact byte counts. Let HTTP establish the actual length.
        return CloudDownload(url: url, filename: file.name, size: 0, headers: ["User-Agent": Self.agent, "Referer": Self.site + "/", "Origin": Self.site])
    }
    private func checkShare(_ share: CloudShare) throws {
        guard share.provider == .ilanzou else { throw CloudError.message("分享与当前平台不一致。") }
        guard share.passcode.isEmpty else { throw CloudError.message("当前蓝奏优享接口不支持提取码，请确认官方分享设置。") }
    }
    func mutate(_ operation: CloudMutation) async throws {
        guard !token.isEmpty else { throw CloudError.message("请先登录蓝奏优享账号。") }
        try await ensureUUID()
        let path: String
        let body: [String: Any]
        switch operation {
        case .createFolder(let name, let parent):
            try Self.validateName(name)
            path = "/proved/file/folder/save"
            body = ["folderDesc": "", "folderId": try ILanzouProtocol.rawID(parent), "folderName": name]
        case .rename(let file, let name):
            try Self.validateName(name)
            path = file.isDirectory ? "/proved/file/folder/edit" : "/proved/file/edit"
            body = file.isDirectory ? ["folderDesc": "", "folderId": try ILanzouProtocol.rawID(file.id), "folderName": name] : ["fileDesc": "", "fileId": try ILanzouProtocol.rawID(file.id), "fileName": name]
        case .move(let file, let parent):
            let source = try ILanzouProtocol.rawID(file.id)
            let target = try ILanzouProtocol.rawID(parent)
            guard !file.isDirectory || source != target else { throw CloudError.message("不能将文件夹移动到自身。") }
            path = "/proved/file/folder/move"
            body = ["folderIds": file.isDirectory ? source : "", "fileIds": file.isDirectory ? "" : source, "targetId": target]
        case .trash(let file):
            let source = try ILanzouProtocol.rawID(file.id)
            path = "/proved/file/delete"
            body = ["folderIds": file.isDirectory ? source : "", "fileIds": file.isDirectory ? "" : source, "status": 0]
        case .save(let file, let share, let parent):
            try checkShare(share)
            let source = try ILanzouProtocol.rawID(file.id)
            path = "/proved/file/transfer"
            body = ["targetFileId": file.isDirectory ? "" : source, "targetFolderId": file.isDirectory ? source : "", "folderId": try ILanzouProtocol.rawID(parent), "shareId": share.shareID]
        }
        let root = try await request(path, authenticated: true, body: body).json
        if case .createFolder = operation {
            let first = (root["list"] as? [[String: Any]])?.first ?? [:]
            let id = Self.string(first["id"])
            guard !id.isEmpty, id != "0" else { throw CloudError.message("蓝奏优享未确认创建文件夹，请刷新后确认。") }
        }
        if case .save = operation {
            let candidates = [Self.string((root["data"] as? [String: Any])?["transferKey"]), Self.string((root["map"] as? [String: Any])?["transferKey"]), Self.string(root["transferKey"]), root["data"] as? String ?? ""]
            guard let key = candidates.first(where: { !$0.isEmpty }) else { return }
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(500))
                let progress = try await request("/proved/file/transfer/num", authenticated: true, parameters: ["transferKey": key]).json
                if Self.string((progress["map"] as? [String: Any])?["num"]) == "1" { return }
            }
            throw CloudError.message("蓝奏优享仍在处理转存，请刷新确认，避免重复提交。")
        }
    }
    private static func validateName(_ name: String) throws {
        try CloudNamePolicy.validate(name)
    }
    private struct Result { let json: [String: Any]; let location: String? }
    private func request(_ path: String, share: CloudShare? = nil, authenticated: Bool = false, parameters: [String: String] = [:], body: [String: Any]? = nil, extra: Bool = true, timestamp: String? = nil, allowLocation: Bool = false) async throws -> Result {
        if authenticated && token.isEmpty { throw CloudError.message("请先登录蓝奏优享账号。") }
        let stamp: String
        if let timestamp { stamp = timestamp }
        else { stamp = try ILanzouProtocol.aesHex(String(Int64(Date().timeIntervalSince1970 * 1000))) }
        var query = ["uuid": uuid, "devType": "6", "devCode": uuid, "devModel": share == nil ? "chrome" : "Chrome", "devVersion": "125", "appVersion": "", "timestamp": stamp]
        if share != nil && allowLocation { query = ["uuid": uuid, "devType": "6", "timestamp": stamp] }
        if authenticated { query["appToken"] = token }
        if extra { query["extra"] = "2" }
        if let share { query["shareId"] = share.shareID }
        query.merge(parameters) { _, value in value }
        let host = share == nil ? "apis.ilanzou.com" : "apix.ilanzou.com"
        let encoded = query.keys.sorted().map { ILanzouProtocol.encode($0) + "=" + ILanzouProtocol.encode(query[$0]!) }.joined(separator: "&")
        guard let url = URL(string: "https://" + host + path + "?" + encoded) else { throw CloudError.message("蓝奏优享请求地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let headers = ["User-Agent": Self.agent, "Origin": Self.site, "Referer": Self.site + "/", "Accept": "application/json, text/plain, */*", "Accept-Language": "zh-CN,zh;q=0.9",
                       "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"", "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": "\"Windows\"", "sec-fetch-dest": "empty", "sec-fetch-mode": "cors", "sec-fetch-site": "same-site"]
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("蓝奏优享响应无效。") }
        if allowLocation, (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url)?.absoluteURL {
            return Result(json: [:], location: target.absoluteString)
        }
        guard (200..<300).contains(http.statusCode), http.mimeType?.lowercased().contains("html") != true else { throw CloudError.message("蓝奏优享请求失败或要求访问验证，请在官网确认后重试。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_097_152 else { throw CloudError.message("蓝奏优享响应超过安全大小。") }
            data.append(byte)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message("蓝奏优享返回格式无效。") }
        let code = Self.string(root["code"])
        let direct = !Self.string(root["url"]).isEmpty || !Self.string((root["data"] as? [String: Any])?["url"]).isEmpty
        guard code == "200" || (allowLocation && code.isEmpty && direct) else { throw CloudError.message("蓝奏优享拒绝请求，请确认登录状态、分享权限或官方验证要求。") }
        return Result(json: root, location: nil)
    }
    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return (value as? NSNumber)?.stringValue ?? ""
    }
}
