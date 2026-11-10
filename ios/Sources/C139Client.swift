// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@MainActor
final class C139Client {
    private let session: URLSession
    private let cookie: String
    private let fields: [String: String]
    private var cursors: [String: [Int: String]] = [:]
    private var more: [String: [Int: Bool]] = [:]
    init(cookie: String, fields: [String: String], session: URLSession) { self.cookie = cookie; self.fields = fields; self.session = session }
    private func identity() throws -> (authorization: String, account: String) { try C139Protocol.identity(cookie: cookie, fields: fields) }
    private func key(_ share: CloudShare?, _ parent: String) -> String { (share.map { $0.shareID + "|" + $0.passcode } ?? "personal") + "|" + parent }
    private func folder(_ parent: String, share: CloudShare?) -> String { parent == "0" || parent.isEmpty ? (share == nil ? "/" : "root") : parent }
    func hasMore(share: CloudShare?, parent: String, page: Int) -> Bool { more[key(share, folder(parent, share: share))]?[page] ?? false }
    func validate() async throws -> String {
        let account = try identity().account
        _ = try await list(share: nil, parent: "/", page: 1)
        return account.count >= 7 ? String(account.prefix(3)) + "****" + String(account.suffix(4)) : "139 用户"
    }
    func list(share: CloudShare?, parent: String, page: Int) async throws -> [CloudFile] {
        guard (1...200).contains(page), share == nil || share?.provider == .c139 else { throw CloudError.message("139 平台或分页参数无效。") }
        let parent = folder(parent, share: share), key = key(share, folder(parent, share: share))
        if page == 1 { more[key] = [:]; cursors[key] = [:] }
        let data: [String: Any], files: [CloudFile]
        if let share {
            data = try await sharePost("IOutLink/getOutLinkInfoV6", body: ["getOutLinkInfoReq": ["account": "", "linkID": share.shareID, "passwd": share.passcode, "caSrt": 1, "coSrt": 1, "srtDr": 0, "bNum": (page - 1) * 100 + 1, "eNum": page * 100, "pCaID": parent]], authenticated: false)
            guard data["caLst"] != nil || data["coLst"] != nil else { throw CloudError.message("139 分享未返回目录数据。") }
            let folders = try (data["caLst"] as? [[String: Any]] ?? []).map { try file($0, parent: parent, folder: true, personal: false) }
            let contents = try (data["coLst"] as? [[String: Any]] ?? []).map { try file($0, parent: parent, folder: Self.string($0["coType"]) == "2" || ($0["isdir"] as? Bool == true), personal: false) }
            var seen = Set<String>()
            files = (folders + contents).filter { seen.insert($0.id).inserted }
            more[key]?[page] = (data["hasMore"] as? Bool) ?? (files.count >= 100)
        } else {
            let cursor: Any
            if page == 1 { cursor = NSNull() }
            else { guard let value = cursors[key]?[page], !value.isEmpty else { throw CloudError.message("139 分页游标已失效，请重新打开目录。") }; cursor = value }
            data = try await cloudPost("/hcy/file/list", body: ["pageInfo": ["pageSize": 100, "pageCursor": cursor], "orderBy": "updated_at", "orderDirection": "DESC", "parentFileId": parent, "imageThumbnailStyleList": ["Small", "Large"]])
            guard let items = data["items"] as? [[String: Any]] else { throw CloudError.message("139 未返回个人目录数据。") }
            files = try items.map { try file($0, parent: parent, folder: Self.string($0["type"]) == "folder", personal: true) }
            cursors[key]?.removeValue(forKey: page + 1)
            let next = Self.string(data["nextPageCursor"])
            if !next.isEmpty {
                guard !cursors[key, default: [:]].values.contains(next) else { throw CloudError.message("139 返回重复分页游标，已停止以免遗漏。") }
                cursors[key]?[page + 1] = next
            }
            more[key]?[page] = !next.isEmpty
        }
        return files
    }
    private func file(_ value: [String: Any], parent: String, folder: Bool, personal: Bool) throws -> CloudFile {
        let id = Self.string(value[personal ? "fileId" : (folder && value["caID"] != nil ? "caID" : "coID")])
        let name = Self.string(value[personal ? "name" : (folder && value["caName"] != nil ? "caName" : "coName")])
        let size = Int64(Self.string(value[personal ? "size" : "coSize"])) ?? 0
        guard !id.isEmpty, !name.isEmpty, size >= 0 else { throw CloudError.message("139 文件信息不完整。") }
        return CloudFile(id: id, name: name, size: size, isDirectory: folder, parentID: parent, token: "")
    }
    func download(file: CloudFile, share: CloudShare?) async throws -> CloudDownload {
        guard !file.isDirectory else { throw CloudError.message("请进入文件夹后选择文件。") }
        let data: [String: Any]
        if let share {
            guard share.provider == .c139 else { throw CloudError.message("139 分享平台不一致。") }
            let account = try identity().account
            data = try await sharePost("IOutLink/dlFromOutLinkV3", body: ["dlFromOutLinkReqV3": ["account": account, "linkID": share.shareID, "coIDLst": ["item": [file.id]], "commonAccountInfo": ["account": account, "accountType": 1]]], authenticated: true)
        } else { data = try await cloudPost("/hcy/file/getDownloadUrl", body: ["fileId": file.id]) }
        let raw = Self.string(data[share == nil ? "url" : "redrUrl"])
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { throw CloudError.message("139 未返回有效 HTTPS 下载地址。") }
        return CloudDownload(url: url, filename: file.name, size: Int64(Self.string(data["size"])) ?? Int64(Self.string(data["coSize"])) ?? file.size, headers: ["User-Agent": C139Protocol.agent, "Referer": "https://yun.139.com/"])
    }
    func mutate(_ operation: CloudMutation) async throws {
        switch operation {
        case .createFolder(let name, let parent):
            try CloudNamePolicy.validate(name)
            let data = try await cloudPost("/hcy/file/create", body: ["parentFileId": folder(parent, share: nil), "name": name, "description": "", "type": "folder", "fileRenameMode": "force_rename"])
            guard !Self.string(data["fileId"]).isEmpty else { throw CloudError.message("139 未确认新建目录结果。") }
        case .rename(let file, let name):
            try CloudNamePolicy.validate(name)
            _ = try await cloudPost("/hcy/file/update", body: ["fileId": file.id, "name": name, "description": ""])
        case .move(let file, let parent):
            guard file.id != parent else { throw CloudError.message("不能移动目录到自身。") }
            let data = try await cloudPost("/hcy/file/batchMove", body: ["fileIds": [file.id], "toParentFileId": folder(parent, share: nil)])
            try await wait(data)
        case .trash(let file):
            let data = try await cloudPost("/hcy/recyclebin/batchTrash", body: ["fileIds": [file.id]])
            try await wait(data)
        case .save(let file, let share, let parent):
            guard share.provider == .c139 else { throw CloudError.message("139 分享平台不一致。") }
            let account = try identity().account
            let taskInfo: [String: Any] = ["contentInfoList": file.isDirectory ? [] : ["/" + file.id], "catalogInfoList": file.isDirectory ? [file.id] : [], "newCatalogID": folder(parent, share: nil), "linkID": share.shareID, "newCatalogName": "手机图片", "needPassword": true]
            let data = try await sharePost("IBatchOprTask/createOuterLinkBatchOprTask", body: ["createOuterLinkBatchOprTaskReq": ["msisdn": account, "ownerAccount": "", "taskType": 1, "taskInfo": taskInfo, "linkID": share.shareID, "needPassword": true], "commonAccountInfo": ["account": account, "accountType": 1]], authenticated: true)
            let taskID = Self.string(data["taskID"])
            guard !taskID.isEmpty else { throw CloudError.message("139 未确认转存任务，请刷新确认。") }
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(1))
                let result = try await sharePost("IBatchOprTask/queryBatchOprTaskDetail", body: ["queryBatchOprTaskDetailReq": ["taskID": taskID, "msisdn": account, "commonAccountInfo": ["account": account, "accountType": 1]]], authenticated: true)
                let task = result["batchOprTask"] as? [String: Any] ?? [:]
                let entries = ((result["contentList"] as? [String: Any])?["idRspInfo"] as? [[String: Any]]) ?? []
                if entries.contains(where: { !Self.string($0["reason"]).isEmpty && Self.string($0["reason"]) != "0000" }) { throw CloudError.message("139 转存有失败项，请刷新确认。") }
                if Self.string(task["taskStatus"]) == "2", (Int(Self.string(task["progress"])) ?? 0) >= 100 { return }
            }
            throw CloudError.message("139 转存仍在处理中，请刷新确认，避免重复提交。")
        }
    }
    private func wait(_ data: [String: Any]) async throws {
        let id = Self.string(data["taskId"])
        guard !id.isEmpty else { throw CloudError.message("139 未确认操作任务，请刷新确认。") }
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(1))
            let data = try await cloudPost("/hcy/task/get", body: ["taskId": id])
            let entries = data["batchFileResults"] as? [[String: Any]] ?? []
            guard !entries.contains(where: { !Self.string($0["errCode"]).isEmpty && !["0", "0000"].contains(Self.string($0["errCode"])) }) else { throw CloudError.message("139 操作有失败项，请刷新确认。") }
            let status = Self.string((data["taskInfo"] as? [String: Any])?["status"])
            if ["Failed", "Canceled"].contains(status) { throw CloudError.message("139 操作失败或已取消。") }
            if status == "Succeed" { return }
            // Progress alone is not proof that every item succeeded.
        }
        throw CloudError.message("139 操作仍在处理中，请刷新确认，避免重复提交。")
    }
    private func cloudPost(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let auth = try identity().authorization, plain = try Self.json(body)
        var request = URLRequest(url: URL(string: "https://personal-kd-njs.yun.139.com" + path)!)
        request.httpMethod = "POST"; request.httpBody = Data(plain.utf8)
        let device = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||"
        let headers = ["Authorization": auth, "mcloud-sign": C139Protocol.signHeader(plain), "x-yun-channel-source": "10000034", "x-yun-app-channel": "10000034", "x-huawei-channelSrc": "10000034", "mcloud-version": "7.17.9", "mcloud-client": "10701", "mcloud-channel": "1000101", "mcloud-route": "001", "x-yun-module-type": "100", "x-yun-api-version": "v1", "x-yun-svc-type": "1", "x-SvcType": "1", "caller": "web", "x-inner-ntwk": "2", "CMS-DEVICE": "default", "x-m4c-src": "10002", "x-m4c-caller": "PC", "X-Deviceinfo": device, "x-yun-client-info": device + "dW5kZWZpbmVk||", "INNER-HCY-ROUTER-HTTPS": "1", "Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty", "X-Requested-With": "mark.via"]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        common(&request, agent: C139Protocol.agent)
        let root = try await send(request, encrypted: false)
        guard root["success"] as? Bool != false, ["0", "0000"].contains(Self.string(root["code"])) else { throw CloudError.message("139 个人盘拒绝请求，请重新登录或检查账号权限。") }
        return root["data"] as? [String: Any] ?? [:]
    }
    private func sharePost(_ path: String, body: [String: Any], authenticated: Bool) async throws -> [String: Any] {
        let plain = try Self.json(body)
        var request = URLRequest(url: URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/" + path)!)
        request.httpMethod = "POST"; request.httpBody = Data(try C139Protocol.encrypt(Data(plain.utf8)).utf8)
        common(&request, agent: C139Protocol.mobileAgent)
        for (name, value) in ["hcy-cool-flag": "1", "x-deviceinfo": "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||", "x-huawei-channelsrc": "10245500", "x-mm-source": "0002"] { request.setValue(value, forHTTPHeaderField: name) }
        if authenticated { request.setValue(try identity().authorization, forHTTPHeaderField: "Authorization"); request.setValue(C139Protocol.signHeader(plain), forHTTPHeaderField: "mcloud-sign") }
        let root = try await send(request, encrypted: true)
        let code = Self.string(root["resultCode"]).isEmpty ? Self.string(root["code"]) : Self.string(root["resultCode"])
        guard root["success"] as? Bool != false, ["0", "0000"].contains(code) else { throw CloudError.message("139 分享拒绝请求，请确认提取码、登录和访问限制。") }
        guard let data = root["data"] as? [String: Any] else { throw CloudError.message("139 分享响应缺少数据。") }
        return data
    }
    private func common(_ request: inout URLRequest, agent: String) {
        request.setValue(agent, forHTTPHeaderField: "User-Agent"); request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://yun.139.com", forHTTPHeaderField: "Origin"); request.setValue("https://yun.139.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }
    private func send(_ request: URLRequest, encrypted: Bool) async throws -> [String: Any] {
        do {
            let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CloudError.message("139 网络请求失败或要求重新登录。") }
            var data = Data()
            for try await byte in bytes { guard data.count < 2_097_152 else { throw CloudError.message("139 响应超过安全大小。") }; data.append(byte) }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return root }
            guard encrypted else { throw CloudError.message("139 返回验证页面或不支持的数据。") }
            let plain = try C139Protocol.decrypt(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            guard let root = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw CloudError.message("139 解密后的数据无效。") }
            return root
        } catch let error as CloudError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("无法连接 139 网盘。") }
    }
    private static func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
    private static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
}
