// SPDX-License-Identifier: AGPL-3.0-only
// Protocol port of desktop Pan123Api.kt / Pan123Constants.kt.
import Foundation

struct Pan123Signature {
    static func crc32(_ text: String) -> String {
        var crc = UInt32.max
        for byte in text.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return String(crc ^ UInt32.max, radix: 16)
    }
    static func make(path: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970), random: Int = Int.random(in: 0..<10_000_000)) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"
        let minute = formatter.string(from: Date(timeIntervalSince1970: Double(timestamp + 57_600)))
        let table = Array("adefghlmyijnopkqrstubcvwsz")
        let mapped = minute.compactMap(\.wholeNumberValue).map { String(table[$0]) }.joined()
        let key = crc32(mapped)
        let value = "\(timestamp)-\(random)-" + crc32("\(timestamp)|\(random)|\(path)|web|3|\(key)")
        return (key, value)
    }
    static func downloadURL(_ text: String) throws -> URL {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = raw
        let wrapped = URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "params" })?.value
        if !raw.contains("://") || wrapped != nil {
            var base64 = (wrapped ?? raw).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) else {
                throw CloudError.message("123 下载包装地址无法解码。")
            }
            candidate = decoded
        }
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw CloudError.message("123 未返回安全的下载地址。") }
        return url
    }
}

@MainActor
final class Pan123Client {
    private let session: URLSession
    private let token: String
    private let device: String
    private var cursors: [String: [Int: String]] = [:]
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool {
        let key = (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent
        return cursors[key]?[page + 1] != nil
    }
    init(token: String, session: URLSession) {
        self.token = token.hasPrefix("Bearer ") ? String(token.dropFirst(7)) : token
        self.session = session
        if let stored = UserDefaults.standard.string(forKey: "pan123Device") { device = stored }
        else { device = UUID().uuidString; UserDefaults.standard.set(device, forKey: "pan123Device") }
    }
    func login(account: String, password: String) async throws -> String {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 254, !password.isEmpty, password.count <= 256 else {
            throw CloudError.message("请输入有效的账号与密码。")
        }
        let result = try await request(host: "user.123pan.cn", path: "/api/user/sign_in", body: ["passport": name, "password": password, "remember": false], login: true)
        guard let token = result["token"] as? String, token.split(separator: ".").count == 3,
              !token.contains(where: { $0.isWhitespace }) else { throw CloudError.message("123 登录未返回有效令牌，可能需要在官方页面完成验证。") }
        return token
    }
    func validate() async throws -> String {
        let result = try await request(path: "/b/api/user/info", authenticated: true)
        guard let name = result["Nickname"] as? String, !name.isEmpty else { throw CloudError.message("123 登录状态无效。") }
        return name
    }
    func mutate(_ operation: CloudMutation) async throws {
        guard !token.isEmpty else { throw CloudError.message("请先登录 123 账号。") }
        let path: String
        let body: [String: Any]
        switch operation {
        case .createFolder(let name, let parent):
            try CloudNamePolicy.validate(name)
            path = "/b/api/file/upload_request"
            body = ["driveId": 0, "parentFileId": try Self.numericID(parent), "fileName": name, "size": 0, "type": 1, "etag": "", "duplicate": 1, "NotReuse": true, "RequestSource": NSNull()]
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            path = "/b/api/file/rename"
            body = ["driveId": 0, "fileId": try Self.numericID(file.id), "fileName": name, "duplicate": 1, "event": "fileRename", "operatePlace": "right", "RequestSource": NSNull()]
        case .move(let file, let parent):
            let target = try Self.numericID(parent)
            let source = try Self.numericID(file.id)
            guard !file.isDirectory || target != source else { throw CloudError.message("不能将文件夹移动到自身。") }
            path = "/b/api/file/mod_pid"
            body = ["fileIdList": [["FileId": source]], "parentFileId": target, "event": "fileMove", "operatePlace": 1, "RequestSource": NSNull()]
        case .trash(let file):
            let metadata = try Self.metadata(file)
            path = "/b/api/file/trash"
            body = ["driveId": 0, "fileTrashInfoList": [["FileId": try Self.numericID(file.id), "FileName": file.name, "Type": file.isDirectory ? 1 : 0,
                    "Size": file.size, "S3KeyFlag": metadata["s3"] ?? "", "Etag": metadata["etag"] ?? ""]], "operation": true, "event": "intoRecycle", "operatePlace": 1, "safeBox": false]
        case .save(let file, let share, let parent):
            try await saveShare(file: file, share: share, parent: parent)
            return
        }
        let data = try await request(path: path, body: body, authenticated: true, allowEmptyData: true)
        if case .createFolder = operation {
            let info = data["Info"] as? [String: Any] ?? [:]
            let id = Self.string(info["FileId"]) ?? Self.string(data["FileId"]) ?? Self.string(data["fileId"]) ?? ""
            guard !id.isEmpty, id != "0" else { throw CloudError.message("123 未确认创建文件夹，请刷新确认。") }
        }
    }
    private func saveShare(file: CloudFile, share: CloudShare, parent: String) async throws {
        guard share.provider == .pan123 else { throw CloudError.message("分享与当前平台不一致。") }
        let metadata = try Self.metadata(file)
        let s3 = metadata["s3"] ?? ""
        let shareID = String(s3.split(separator: "-").first ?? "")
        guard shareID.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil else { throw CloudError.message("123 分享缺少数值 ShareId，请重新解析。") }
        let source = try Self.numericID(file.id)
        let target = try Self.numericID(parent)
        let record: [String: Any] = ["fileID": source, "fileId": source, "size": file.size, "etag": metadata["etag"] ?? "", "type": file.isDirectory ? 1 : 0,
                                    "parentFileID": target, "parentFileId": target, "fileName": file.name, "driveID": 0, "driveId": 0,
                                    "s3keyFlag": s3, "S3KeyFlag": s3, "StorageNode": metadata["storage"] ?? ""]
        let host = shareID + ".mshare.123pan.cn"
        let path = "/b/api/restful/goapi/v1/file/copy/save"
        let data = try await request(host: host, path: path, body: ["fileList": [record], "shareKey": share.shareID, "sharePwd": share.passcode, "currentLevel": 1, "superAdmin": NSNull()], authenticated: true, sign: false)
        guard let task = Self.string(data["taskID"]), let number = Int64(task), number > 0 else { throw CloudError.message("123 未返回转存任务，请刷新个人目录确认。") }
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(1))
            let progress = try await request(host: host, path: path + "/get", query: ["taskID": task], authenticated: true, sign: false)
            let state = (Self.string(progress["state"]) ?? "").lowercased()
            if ["failed", "error"].contains(state) { throw CloudError.message("123 转存任务失败，请确认空间和权限。") }
            if progress["finished"] as? Bool == true || Self.string(progress["status"]) == "2" || ["success", "done", "2"].contains(state) || !(Self.string(progress["newFileId"]) ?? "").isEmpty { return }
        }
        throw CloudError.message("123 转存仍在处理中或未返回明确完成状态，请刷新个人目录确认，避免重复提交。")
    }
    private static func numericID(_ value: String) throws -> Int64 {
        guard value.range(of: "^[0-9]+$", options: .regularExpression) != nil, let id = Int64(value), id >= 0 else { throw CloudError.message("123 文件标识无效。") }
        return id
    }
    private static func metadata(_ file: CloudFile) throws -> [String: String] {
        guard let data = Data(base64Encoded: file.token), let metadata = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw CloudError.message("123 文件元信息缺失，请重新解析。") }
        return metadata
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard page >= 1, page <= 200 else { throw CloudError.message("123 分页参数无效。") }
        if let share, share.provider != .pan123 { throw CloudError.message("分享与当前平台不一致。") }
        let key = (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent
        let cursor: String
        if page == 1 { cursor = "0"; cursors[key] = [1: "0"] }
        else {
            guard let value = cursors[key]?[page] else { return [] }
            cursor = value
        }
        var query = ["limit": "100", "next": cursor, "orderBy": "file_name", "orderDirection": "asc", "Page": String(page)]
        let path: String
        if let share {
            path = "/b/api/share/get"
            query["shareKey"] = share.shareID; query["ParentFileId"] = parent
            if !share.passcode.isEmpty { query["SharePwd"] = share.passcode }
        } else {
            path = "/b/api/file/list/new"
            query.merge(["parentFileId": parent, "driveId": "0", "trashed": "false", "SearchData": "", "OnlyLookAbnormalFile": "0", "event": "homeListFile", "operateType": "1", "inDirectSpace": "false"]) { _, value in value }
        }
        let data = try await request(path: path, query: query, authenticated: share == nil)
        guard data["Expired"] as? Bool != true else { throw CloudError.message("123 分享已失效。") }
        guard let records = data["InfoList"] as? [[String: Any]] else { throw CloudError.message("123 未返回文件列表。") }
        cursors[key]?[page + 1] = nil
        if let next = data["Next"], String(describing: next) != "-1", !records.isEmpty {
            cursors[key]?[page + 1] = String(describing: next)
        }
        return try records.map { item in
            guard let id = Self.string(item["FileId"]), !id.isEmpty, let name = item["FileName"] as? String else {
                throw CloudError.message("123 文件条目信息不完整，已停止显示该页。")
            }
            let metadata = ["s3": Self.string(item["S3KeyFlag"]) ?? "", "etag": item["Etag"] as? String ?? "", "storage": Self.string(item["StorageNode"]) ?? ""]
            let encoded = try JSONSerialization.data(withJSONObject: metadata).base64EncodedString()
            return CloudFile(id: id, name: name, size: (item["Size"] as? NSNumber)?.int64Value ?? 0,
                             isDirectory: (item["Type"] as? NSNumber)?.intValue == 1,
                             parentID: Self.string(item["ParentFileId"]) ?? parent, token: encoded)
        }
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory, let data = Data(base64Encoded: file.token),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let s3 = metadata["s3"], let etag = metadata["etag"], !etag.isEmpty else { throw CloudError.message("123 文件信息不完整，请重新解析。") }
        let result: [String: Any]
        let raw: String?
        if let share {
            guard share.provider == .pan123 else { throw CloudError.message("分享与当前平台不一致。") }
            result = try await request(host: "www.123865.com", path: "/b/api/share/download/info", body: ["ShareKey": share.shareID, "FileID": file.id, "S3KeyFlag": s3, "Size": file.size, "Etag": etag], authenticated: true, android: true)
            raw = result["DownloadURL"] as? String
        } else {
            guard let id = Int64(file.id) else { throw CloudError.message("123 文件 ID 无效。") }
            result = try await request(path: "/api/file/download_info", body: ["driveId": 0, "etag": etag, "fileId": id, "s3keyFlag": s3, "type": 0, "fileName": file.name, "size": file.size], authenticated: true)
            raw = result["DownloadUrl"] as? String
        }
        guard let raw else { throw CloudError.message("123 未返回下载链接，请检查账号和流量限制。") }
        var url = try Pan123Signature.downloadURL(raw)
        var seen = Set<URL>()
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard seen.insert(url).inserted else { throw CloudError.message("123 下载跳转发生循环。") }
            // Probe only explicit JSON redirect links; never send API Authorization to a CDN.
            guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "auto_redirect" && $0.value == "0" }) == true else {
                return CloudDownload(url: url, filename: file.name, size: file.size, headers: ["Referer": "https://yun.123pan.cn/", "User-Agent": "Dart/3.12 (dart:io)"])
            }
            var probe = URLRequest(url: url)
            probe.setValue("https://yun.123pan.cn/", forHTTPHeaderField: "Referer")
            probe.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: probe)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw CloudError.message("123 下载跳转响应无效。") }
            if let location = http.value(forHTTPHeaderField: "Location"), (300..<400).contains(http.statusCode) {
                guard let resolved = URL(string: location, relativeTo: url)?.absoluteURL else { throw CloudError.message("123 跳转地址无效。") }
                url = try Pan123Signature.downloadURL(resolved.absoluteString); continue
            }
            guard (200..<300).contains(http.statusCode) else { throw CloudError.message("123 下载地址已失效，请重新取链。") }
            var body = Data()
            for try await byte in bytes {
                if body.count >= 8192 { break }
                body.append(byte)
            }
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let next = (json["data"] as? [String: Any])?["redirect_url"] as? String, !next.isEmpty {
                url = try Pan123Signature.downloadURL(next)
            } else {
                guard !body.starts(with: Data("{".utf8)) else { throw CloudError.message("123 返回错误数据，未作为文件下载。") }
                return CloudDownload(url: url, filename: file.name, size: file.size, headers: ["Referer": "https://yun.123pan.cn/", "User-Agent": "Dart/3.12 (dart:io)"])
            }
        }
        throw CloudError.message("123 下载跳转次数过多。")
    }
    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func request(host: String = "yun.123pan.cn", path: String, query: [String: String] = [:], body: [String: Any]? = nil,
                         authenticated: Bool = false, login: Bool = false, android: Bool = false, sign: Bool = true, allowEmptyData: Bool = false) async throws -> [String: Any] {
        guard !authenticated || !token.isEmpty else { throw CloudError.message("123 取链或浏览个人盘需要登录，请到账号页登录或保存 JWT。") }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.path = path
        parts.queryItems = query.isEmpty ? nil : query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw CloudError.message("123 请求地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("web", forHTTPHeaderField: "platform")
        request.setValue(login ? "132" : "3", forHTTPHeaderField: "app-version")
        request.setValue(device, forHTTPHeaderField: "loginuuid")
        request.setValue(MediaClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if login {
            request.setValue("https://user.123pan.cn", forHTTPHeaderField: "Origin")
            request.setValue("https://user.123pan.cn/", forHTTPHeaderField: "Referer")
        }
        if authenticated {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if sign {
                let (key, value) = Pan123Signature.make(path: path)
                request.setValue(key, forHTTPHeaderField: "auth-key"); request.setValue(value, forHTTPHeaderField: "auth-value")
            } else { request.setValue("Dart/3.12 (dart:io)", forHTTPHeaderField: "User-Agent") }
        }
        if android { request.setValue("android", forHTTPHeaderField: "platform"); request.setValue("39", forHTTPHeaderField: "app-version") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接 123 云盘服务。") }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("123 请求失败，请检查网络或登录状态。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw CloudError.message("123 接口响应过大。") }
            data.append(byte)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == (login ? 200 : 0) else { throw CloudError.message(login ? "123 登录被拒绝，请检查账号密码并在官网完成必要验证。" : "123 拒绝请求，请检查分享、提取码、登录或下载限制。") }
        if let value = root["data"] as? [String: Any] { return value }
        if allowEmptyData { return [:] }
        throw CloudError.message("123 未返回有效数据，请重新解析或刷新目录。")
    }
}
