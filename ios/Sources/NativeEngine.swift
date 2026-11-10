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
    private var proxyResolver: IOSProxyResolver?
    private var activeOperations = 0
    private var watchedCompletions = Set<String>()
    private var completionMonitor: Task<Void, Never>?
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/Engine", isDirectory: true)
    nonisolated let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("P2P", isDirectory: true)

    func ensureStarted() async throws {
        if let startup { return try await startup.value }
        guard !DownloadStorage.isMigrating else { throw DownloadStorageError.busy }
        try Self.applyHTTPBandwidthLimit(UserDefaults.standard.integer(forKey: "engineHTTPRateKiB"))
        _ = try NetworkProxy.current()
        let resolver = IOSProxyResolver()
        proxyResolver = resolver
        let root = support
        let destination = downloads
        let dht = UserDefaults.standard.bool(forKey: "engineDHT")
        let operation = Task.detached(priority: .utility) {
            try DownloadStorage.prepare()
            try Self.bindProxy(resolver)
            for folder in [root, destination] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let config: [String: Any] = [
                "apiEnable": false, "mcpEnable": false, "storage": "bolt", "storageDir": root.path,
                // Gopeed uses filepath.Match, not recursive containment. Every task owns one UUID child.
                "tempDir": root.appendingPathComponent("Cache").path, "whiteDownloadDirs": [destination.path, destination.path + "/*"],
                "downloadConfig": ["downloadDir": destination.path, "maxRunning": 3, "autoStartTasks": false, "proxy": ["enable": false],
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
        do { try await operation.value; await Diagnostics.shared.record(.engineStarted) }
        catch { startup = nil; proxyResolver = nil; await Diagnostics.shared.record(.engineStartFailed); throw error }
    }
    private static func bindProxy(_ resolver: IOSProxyResolver) throws {
        var error: NSError?
        guard YunxengineSetProxyResolver(resolver, &error) else { throw CloudError.message("原生引擎代理配置失败，请重启应用后重试。") }
    }
    private static func applyHTTPBandwidthLimit(_ kibPerSecond: Int) throws {
        guard (0...1_048_576).contains(kibPerSecond) else { throw CloudError.message("原生 HTTP 限速需为 0–1048576 KiB/s，0 表示不限。") }
        var error: NSError?
        guard YunxengineSetNativeHTTPBandwidthLimit(Int64(kibPerSecond) * 1024, &error) else {
            throw CloudError.message("原生 HTTP 限速设置失败。")
        }
    }
    func setHTTPBandwidthLimit(kibPerSecond: Int) throws {
        try Self.applyHTTPBandwidthLimit(kibPerSecond)
        UserDefaults.standard.set(kibPerSecond, forKey: "engineHTTPRateKiB")
    }
    func refreshNetworkProxy(profile: NetworkProxyProfile? = nil, startIfNeeded: Bool = false) async throws {
        guard startup != nil || startIfNeeded else { return }
        try await ensureStarted()
        let normalized = try profile.map { try $0.validated() }
        let resolver = IOSProxyResolver(profile: normalized)
        try await Task.detached(priority: .utility) { try Self.bindProxy(resolver) }.value
        proxyResolver = resolver
    }
    func invoke(_ method: String, path: String, query: String = "", body: Data? = nil) async throws -> Data {
        guard !DownloadStorage.isMigrating || path.hasSuffix("/pause") else { throw DownloadStorageError.busy }
        try await ensureStarted()
        guard !DownloadStorage.isMigrating || path.hasSuffix("/pause") else { throw DownloadStorageError.busy }
        activeOperations += 1
        defer { activeOperations -= 1 }
        let encoded = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let data = try await Task.detached(priority: .utility) {
            let response = YunxengineInvoke(method, path, query, encoded)
            guard let data = response.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["code"] as? Int == 0 else {
                await Diagnostics.shared.record(.engineOperationFailed)
                throw CloudError.message("引擎拒绝操作，请检查任务状态、资源和网络。")
            }
            return data
        }.value
        if UserDefaults.standard.bool(forKey: DownloadNotifications.preferenceKey) {
            if method == "POST", path == "/api/v1/tasks", let id = (try? JSONDecoder().decode(EngineEnvelope<String>.self, from: data))?.data {
                watchedCompletions.insert(id)
            } else if method == "PUT", path.hasSuffix("/continue") {
                let parts = path.split(separator: "/")
                if parts.count == 5 { watchedCompletions.insert(String(parts[3])) }
            }
            beginCompletionWatch()
        }
        return data
    }
    func quiesceForStorage() async throws {
        completionMonitor?.cancel(); completionMonitor = nil
        let deadline = Date().addingTimeInterval(60)
        while activeOperations > 0 {
            guard Date() < deadline else { throw DownloadStorageError.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let startup else { return }
        try await startup.value
        let closed = await Task.detached(priority: .utility) {
            var error: NSError?
            return YunxengineStopForStorage(&error)
        }.value
        self.startup = nil; proxyResolver = nil
        guard closed else { DownloadStorage.failClosed(); throw DownloadStorageError.unavailable }
    }
    func watchCurrentCompletions() async {
        guard startup != nil, UserDefaults.standard.bool(forKey: DownloadNotifications.preferenceKey), let current = try? await tasks() else { return }
        watchedCompletions.formUnion(current.filter { ["ready", "wait", "running"].contains($0.status) }.map(\.id))
        beginCompletionWatch()
    }
    private func beginCompletionWatch() {
        guard completionMonitor == nil, !watchedCompletions.isEmpty else { return }
        completionMonitor = Task {
            while !Task.isCancelled, !watchedCompletions.isEmpty, UserDefaults.standard.bool(forKey: DownloadNotifications.preferenceKey) {
                do {
                    let current = try await tasks()
                    for id in watchedCompletions {
                        guard let task = current.first(where: { $0.id == id }) else { watchedCompletions.remove(id); continue }
                        if task.meta?.req?.labels?["yunxAssembly"] != nil || ["error", "pause"].contains(task.status) {
                            watchedCompletions.remove(id)
                        } else if task.status == "done" {
                            watchedCompletions.remove(id)
                            if !completedFiles(task).isEmpty { await DownloadNotifications.shared.completed() }
                        }
                    }
                } catch { /* A transient stats failure does not create a completion event. */ }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
            watchedCompletions.removeAll()
            completionMonitor = nil
        }
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
