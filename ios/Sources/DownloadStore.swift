// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import UniformTypeIdentifiers

struct DownloadItem: Codable, Identifiable {
    enum State: String, Codable {
        case waiting, downloading, pausing, paused, completed, failed
        var title: String {
            switch self {
            case .waiting: return "等待中"
            case .downloading: return "下载中"
            case .pausing: return "正在暂停"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            }
        }
    }
    let id: UUID
    let url: URL
    var filename: String
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var requiresHeaders: Bool?
    var preserveFilename: Bool?
    var requiredSize: Int64?
    var sha256: String?
    var expectedMedia: String?
}

/// URLSession 的委托队列显式使用主队列；所有 UI 操作也在主线程执行。
/// 本阶段使用前台会话，不宣称支持长时间后台下载。
final class DownloadStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    @Published var storageError: String?
    @Published private(set) var hashing = Set<UUID>()
    @Published var maximumConcurrent = max(1, min(6, UserDefaults.standard.integer(forKey: "downloadConcurrency") == 0 ? 3 : UserDefaults.standard.integer(forKey: "downloadConcurrency"))) {
        didSet {
            UserDefaults.standard.set(maximumConcurrent, forKey: "downloadConcurrency")
            drainQueue()
        }
    }
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var removed = Set<UUID>()
    private let root: URL
    private let cache: URL
    private var session: URLSession!
    private let manager = FileManager.default

    override init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YunX", isDirectory: true)
        super.init()
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            let index = cache.appendingPathComponent("tasks.json")
            if manager.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: index))
                for index in items.indices where [.downloading, .pausing, .waiting].contains(items[index].state) {
                    items[index].state = .paused
                }
            }
        } catch {
            storageError = "无法读取下载记录：\(error.localizedDescription)"
        }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    @discardableResult
    func add(_ url: URL, filename: String? = nil, headers: [String: String] = [:],
             expectedSize: Int64? = nil, expectedMedia: String? = nil) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            storageError = "只接受 HTTP 或 HTTPS 文件直链"
            return false
        }
        let name = safeName(filename ?? url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        var item = DownloadItem(id: UUID(), url: url, filename: name, state: .waiting)
        item.requiresHeaders = !headers.isEmpty
        item.preserveFilename = filename != nil
        item.requiredSize = expectedSize
        item.expectedMedia = expectedMedia
        if !headers.isEmpty {
            do { try DownloadHeaders.save(headers, id: item.id) }
            catch { storageError = error.localizedDescription; return false }
        }
        storageError = nil
        items.insert(item, at: 0)
        Task { await Diagnostics.shared.record(.downloadAdded) }
        save()
        start(item.id)
        return true
    }

    func start(_ id: UUID) {
        guard active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              [.waiting, .paused, .failed].contains(items[index].state) else { return }
        items[index].state = .waiting
        items[index].error = nil
        save()
        drainQueue()
    }

    private func drainQueue() {
        for id in items.reversed().filter({ $0.state == .waiting }).map(\.id) {
            guard active.count < max(1, min(6, maximumConcurrent)) else { break }
            launch(id)
        }
    }

    func pauseAll() {
        for id in items.filter({ [.waiting, .downloading].contains($0.state) }).map(\.id) {
            pause(id)
        }
    }

    func resumeAll() {
        for index in items.indices where [.paused, .failed].contains(items[index].state) {
            items[index].state = .waiting
            items[index].error = nil
        }
        save()
        drainQueue()
    }

    private func launch(_ id: UUID) {
        guard active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              items[index].state != .completed, items[index].state != .pausing else { return }
        var request = URLRequest(url: items[index].url)
        if items[index].requiresHeaders == true {
            do {
                for (key, value) in try DownloadHeaders.load(id) {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            } catch {
                items[index].state = .failed
                items[index].error = "下载凭证不可用，请解锁设备或重新解析文件。"
                save()
                return
            }
        }
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(id)) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        active[id] = task
        items[index].state = .downloading
        items[index].error = nil
        save()
        task.resume()
    }

    func pause(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting {
            items[index].state = .paused
            save()
            return
        }
        guard let task = active[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .pausing
        save()
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self, !self.removed.contains(id),
                      let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.writeResume(data, id: id)
                self.active.removeValue(forKey: id)
                self.items[index].state = .paused
                self.save()
                self.drainQueue()
            }
        }
    }

    func delete(_ id: UUID) {
        removed.insert(id)
        active.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
        try? manager.removeItem(at: resumeURL(id))
        DownloadHeaders.delete(id)
        // 下载完成的文件保留，删除记录不会隐式删除用户文件。
        save()
        drainQueue()
    }

    func fileURL(_ item: DownloadItem) -> URL? {
        guard item.state == .completed else { return nil }
        let url = root.appendingPathComponent(item.filename)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    func calculateChecksum(_ id: UUID) {
        guard !hashing.contains(id), let item = items.first(where: { $0.id == id }), let file = fileURL(item) else { return }
        hashing.insert(id)
        Task { @MainActor [weak self] in
            defer { self?.hashing.remove(id) }
            do {
                let digest = try await Task.detached(priority: .utility) { try FileDigest.sha256(file) }.value
                guard let self, let index = self.items.firstIndex(where: { $0.id == id && $0.state == .completed }) else { return }
                self.items[index].sha256 = digest
                self.save()
            } catch { self?.storageError = "无法计算文件 SHA-256，请确认文件存在且未被修改。" }
        }
    }

    private func resumeURL(_ id: UUID) -> URL {
        cache.appendingPathComponent("\(id.uuidString).resume")
    }

    private func writeResume(_ data: Data?, id: UUID) {
        guard let data else { return }
        do { try data.write(to: resumeURL(id), options: [.atomic, .completeFileProtection]) }
        catch { storageError = "无法保存断点：\(error.localizedDescription)" }
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(
                to: cache.appendingPathComponent("tasks.json"),
                options: [.atomic, .completeFileProtection]
            )
        } catch { storageError = "无法保存下载记录：\(error.localizedDescription)" }
    }

    private func safeName(_ raw: String) -> String {
        FileNamePolicy.name(raw)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].received = totalBytesWritten
        items[index].expected = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            Task { await Diagnostics.shared.record(.downloadFailed, code: status) }
            items[index].state = .failed
            items[index].error = "服务器未返回成功的 HTTP 状态"
            save()
            return
        }
        do {
            if let expected = items[index].requiredSize, expected > 0 {
                let actual = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard Int64(actual) == expected else {
                    throw CloudError.message("返回文件大小与平台记录不一致，已拒绝保存。")
                }
            }
            let initialName = items[index].preserveFilename == true ? items[index].filename :
                safeName(response.suggestedFilename ?? items[index].filename)
            let proposed = try MediaFileValidation.filename(initialName, file: location, kind: items[index].expectedMedia, mime: response.mimeType)
            let original = URL(fileURLWithPath: proposed)
            let ext = original.pathExtension
            let stem = original.deletingPathExtension().lastPathComponent
            var destination = root.appendingPathComponent(proposed)
            if manager.fileExists(atPath: destination.path) {
                let suffix = id.uuidString
                destination = root.appendingPathComponent(
                    ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                )
            }
            try manager.moveItem(at: location, to: destination)
            items[index].filename = destination.lastPathComponent
            items[index].state = .completed
            items[index].received = (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init) ?? items[index].received
            try? manager.removeItem(at: resumeURL(id))
            DownloadHeaders.delete(id)
            let size = items[index].received
            Task { await Diagnostics.shared.record(.downloadCompleted, bytes: size) }
        } catch {
            items[index].state = .failed
            items[index].error = "无法保存文件：\(error.localizedDescription)"
            Task { await Diagnostics.shared.record(.downloadFailed) }
        }
        save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if let raw = task.taskDescription, let id = UUID(uuidString: raw),
           let item = items.first(where: { $0.id == id }), item.requiresHeaders == true {
            let headers = (try? DownloadHeaders.load(id)) ?? [:]
            for key in ["Cookie", "Authorization", "Proxy-Authorization"] {
                redirected.setValue(nil, forHTTPHeaderField: key)
            }
            for (key, value) in DownloadHeaders.redirectHeaders(headers, original: item.url, target: target) {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        if let current = active[id], current.taskIdentifier != task.taskIdentifier { return }
        active.removeValue(forKey: id)
        defer { drainQueue() }
        guard !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state == .pausing { return }
        if items[index].state == .paused, let cancellation = error as NSError?,
           cancellation.domain == NSURLErrorDomain, cancellation.code == NSURLErrorCancelled { return }
        if let error = error as NSError? {
            let code = error.code
            Task { await Diagnostics.shared.record(.downloadFailed, code: code) }
            writeResume(error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, id: id)
            items[index].state = .failed
            // 不展示 NSError 描述，避免把带有凭证的完整请求 URL 显示或记录。
            items[index].error = "网络错误（\(error.domain)，\(error.code)），可重试"
            // 系统未提供可恢复数据时丢弃旧断点，下次重试从原始 URL 开始。
            if error.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
                try? manager.removeItem(at: resumeURL(id))
            }
        }
        save()
    }
}
