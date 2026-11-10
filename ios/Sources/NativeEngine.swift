// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Yunxengine

struct EngineEnvelope<T: Decodable>: Decodable {
    let code: Int
    let data: T?
}
struct EngineTask: Decodable, Identifiable {
    struct Progress: Decodable { let downloaded: Int64?; let speed: Int64? }
    struct Metadata: Decodable {
        struct Request: Decodable { let labels: [String: String]? }
        let req: Request?
        struct Options: Decodable { let path: String? }
        struct Resource: Decodable { let size: Int64? }
        let opts: Options?
        let res: Resource?
    }
    let id: String
    let name: String
    let status: String
    let `protocol`: String
    let progress: Progress?
    let meta: Metadata?
    var statusTitle: String {
        switch status {
        case "ready": return "正在解析…"
        case "running": return "下载中"
        case "wait": return "等待中"
        case "pause": return "已暂停"
        case "done": return "已完成"
        case "error": return "失败，可重试"
        default: return "正在处理…"
        }
    }
}

actor NativeEngine {
    static let shared = NativeEngine()
    private var startup: Task<Void, Error>?
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/Engine", isDirectory: true)
    nonisolated let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("P2P", isDirectory: true)

    func ensureStarted() async throws {
        if let startup { return try await startup.value }
        let root = support
        let destination = downloads
        let dht = UserDefaults.standard.bool(forKey: "engineDHT")
        let operation = Task.detached(priority: .utility) {
            for folder in [root, destination] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let config: [String: Any] = [
                "apiEnable": false, "mcpEnable": false, "storage": "bolt", "storageDir": root.path,
                "tempDir": root.appendingPathComponent("Cache").path, "whiteDownloadDirs": [destination.path],
                "downloadConfig": ["downloadDir": destination.path, "maxRunning": 3, "autoStartTasks": false,
                    "protocolConfig": ["bt": ["disableDht": !dht, "disablePex": true, "autoUpdateTrackers": false,
                        "customTrackers": [], "trackerSubscribeUrls": [], "seedKeep": false, "seedRatio": 0, "seedTime": 0]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: config)
            guard let json = String(data: data, encoding: .utf8) else { throw CloudError.message("引擎配置无效。") }
            var port = 0
            var error: NSError?
            guard YunxengineStart(json, &port, &error) else { throw CloudError.message("本机下载引擎启动失败，请检查设备存储或重启应用。") }
        }
        startup = operation
        do { try await operation.value }
        catch { startup = nil; throw error }
    }
    func invoke(_ method: String, path: String, query: String = "", body: Data? = nil) async throws -> Data {
        try await ensureStarted()
        let encoded = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return try await Task.detached(priority: .utility) {
            let response = YunxengineInvoke(method, path, query, encoded)
            guard let data = response.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0 else {
                throw CloudError.message("引擎拒绝操作，请检查任务状态、资源和网络。")
            }
            return data
        }.value
    }
    func managementServerRunning() -> Bool { YunxengineServerRunning() }
    func tasks() async throws -> [EngineTask] {
        let data = try await invoke("GET", path: "/api/v1/tasks")
        return try JSONDecoder().decode(EngineEnvelope<[EngineTask]>.self, from: data).data ?? []
    }
    func create(_ url: String, trackers: [String]) async throws {
        let folder = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let request: [String: Any] = ["req": ["url": url, "extra": ["trackers": trackers]],
            "opts": ["path": folder.path, "skipAutoCategorize": true]]
        _ = try await invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: request))
    }
    @discardableResult
    func createHTTPS(_ request: NativeHTTPSRequest) async throws -> String {
        let folder = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let data = try await invoke("POST", path: "/api/v1/tasks", body: request.body(folder: folder))
        guard let id = try JSONDecoder().decode(EngineEnvelope<String>.self, from: data).data else { throw CloudError.message("引擎未返回任务 ID。") }
        return id
    }
    func createHLS(_ asset: MediaAsset) async throws {
        guard asset.isHLS, asset.url.scheme == "https", asset.url.pathExtension.lowercased() == "m3u8",
              !asset.headers.keys.contains(where: { ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased()) }) else {
            throw CloudError.message("此 HLS 下载不支持携带账号凭证或非 HTTPS 播放列表。")
        }
        let request: [String: Any] = ["req": ["url": asset.url.absoluteString, "extra": ["header": asset.headers]]]
        let resolved = try await invoke("POST", path: "/api/v1/resolve", body: JSONSerialization.data(withJSONObject: request))
        guard let root = try JSONSerialization.jsonObject(with: resolved) as? [String: Any],
              let data = root["data"] as? [String: Any], let rid = data["id"] as? String,
              let resource = data["res"] as? [String: Any], let files = resource["files"] as? [[String: Any]],
              let original = files.first?["name"] as? String else { throw CloudError.message("HLS 引擎未返回有效输出计划。") }
        let ext = (original as NSString).pathExtension.lowercased()
        guard ["ts", "mp4", "m4a", "aac"].contains(ext) else { throw CloudError.message("HLS 引擎返回了不受支持的输出容器。") }
        let name = FileNamePolicy.name((asset.filename as NSString).deletingPathExtension + "." + ext)
        let folder = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let create: [String: Any] = ["rid": rid, "opts": ["path": folder.path, "name": name, "skipAutoCategorize": true]]
        _ = try await invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: create))
    }
    func configure(trackers: [String], dht: Bool, parallel: Int) async throws {
        let data = try await invoke("GET", path: "/api/v1/config")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var config = root["data"] as? [String: Any] else { throw CloudError.message("无法读取引擎配置。") }
        var protocols = config["protocolConfig"] as? [String: Any] ?? [:]
        var bt = protocols["bt"] as? [String: Any] ?? [:]
        bt["customTrackers"] = trackers; bt["disableDht"] = !dht
        bt["autoUpdateTrackers"] = false; bt["trackerSubscribeUrls"] = [String]()
        protocols["bt"] = bt
        config["protocolConfig"] = protocols; config["maxRunning"] = max(1, min(6, parallel))
        _ = try await invoke("PUT", path: "/api/v1/config", body: JSONSerialization.data(withJSONObject: config))
    }
    nonisolated func completedFiles(_ task: EngineTask) -> [URL] {
        guard task.status == "done", let path = task.meta?.opts?.path else { return [] }
        let root = downloads.resolvingSymlinksInPath().standardizedFileURL
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard folder.path.hasPrefix(root.path + "/"),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(folder.path + "/"), (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(resolved)
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
